import Foundation
import Supabase

/// LIVE Supabase check: create → rename → soft-delete a root folder via outbox drain.
/// Credentials from launch env `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD` (never hardcoded).
enum LiveFolderSyncVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
    }

    static func run() -> Result {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.value = try await runThrowing()
            } catch {
                var detail = error.localizedDescription
                if let pg = error as? PostgrestError {
                    detail = "code=\(pg.code ?? "?") message=\(pg.message) details=\(pg.details ?? "nil")"
                }
                box.value = Result(passed: false, message: "Threw: \(detail)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 90)
        return box.value ?? Result(passed: false, message: "Live folder sync timed out")
    }

    private static func runThrowing() async throws -> Result {
        guard SupabaseManager.isConfigured else {
            return Result(passed: false, message: "Supabase is not configured")
        }
        let email = ProcessInfo.processInfo.environment["BT_LIVE_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = ProcessInfo.processInfo.environment["BT_LIVE_PASSWORD"] ?? ""
        guard !email.isEmpty, !password.isEmpty else {
            return Result(
                passed: false,
                message: "Missing BT_LIVE_EMAIL / BT_LIVE_PASSWORD launch environment"
            )
        }

        // Dedicated client so AuthStore session observers cannot clear auth mid-check.
        let client = SupabaseClient(
            supabaseURL: try SupabaseConfig.makeURL(),
            supabaseKey: try SupabaseConfig.makeAnonKey()
        )
        _ = try await client.auth.signIn(email: email, password: password)
        defer { Task { try? await client.auth.signOut() } }

        let session = try await client.auth.session
        let userId = session.user.id

        let projects: [CloudProject] = try await client
            .from("projects")
            .select("id,name,owner_id,created_at")
            .order("created_at", ascending: false)
            .execute()
            .value

        let projectId: UUID
        if let existing = projects.first {
            projectId = existing.id
        } else {
            // Insert without representation — RETURNING can fail RLS until membership is visible.
            try await client
                .from("projects")
                .insert(LiveProjectInsert(name: "Live Folder Sync", ownerId: userId))
                .execute()
            let refreshed: [CloudProject] = try await client
                .from("projects")
                .select("id,name,owner_id,created_at")
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            guard let created = refreshed.first else {
                return Result(
                    passed: false,
                    message: "Could not create or load a project for live folder sync"
                )
            }
            projectId = created.id
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-live-folder-sync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folderId = UUID()
        let createOp = UUID()
        let renameOp = UUID()
        let deleteOp = UUID()
        let stamp = Int(Date().timeIntervalSince1970)
        let createName = "BT Live \(stamp)"
        let renameName = "BT Live Renamed \(stamp)"

        var folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: createName,
            sortOrder: 0,
            createdDate: Date()
        )

        // Isolated temp SQLite — never touch AppDatabase.shared / live Documents outbox.
        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live", createdDate: Date()))
        try db.persistDrawingFolderCreate(folder, operationId: createOp)
        // Distinct created_at so FIFO order is stable when ops are enqueued back-to-back.
        Thread.sleep(forTimeInterval: 0.05)
        folder.name = renameName
        try db.persistDrawingFolderRename(folder, operationId: renameOp)
        Thread.sleep(forTimeInterval: 0.05)
        try db.persistDrawingFolderDelete(folder, operationId: deleteOp)

        let queuedOps = try db.fetchAllOutboxEntries().map(\.operation)
        guard queuedOps == [.create, .update, .delete] else {
            return Result(
                passed: false,
                message: "Expected create→rename→delete outbox order, got \(queuedOps.map(\.rawValue))"
            )
        }

        let remote = SupabaseDrawingFolderRemoteStore(client: client)

        // Preflight: same auth must be allowed to edit this project.
        struct CanEditParams: Encodable { let p_project_id: UUID }
        let canEdit: Bool = try await client
            .rpc("can_edit_project", params: CanEditParams(p_project_id: projectId))
            .execute()
            .value
        guard canEdit else {
            return Result(
                passed: false,
                message: "can_edit_project=false for project \(projectId) user \(userId)"
            )
        }

        // Stepwise: create, verify remote name; rename, verify; delete, verify hidden + empty outbox.
        let createEntry = try db.fetchAllOutboxEntries()[0]
        let createFolder = try SyncOutboxPushService.folder(from: createEntry)
        guard createFolder.projectId == projectId else {
            return Result(
                passed: false,
                message: "Outbox payload project mismatch \(createFolder.projectId) vs \(projectId)"
            )
        }
        do {
            _ = try await remote.ensureCreated(createFolder)
        } catch {
            return Result(passed: false, message: "CREATE failed: \(Self.describe(error))")
        }
        try db.markOutboxSent(operationId: createEntry.id)

        let afterCreate: [LiveFolderProbe] = try await client
            .from("drawing_folders")
            .select("id,name,deleted_at")
            .eq("id", value: folderId.uuidString)
            .execute()
            .value
        guard afterCreate.count == 1, afterCreate[0].name == createName else {
            return Result(
                passed: false,
                message: "Create not visible in Postgres (count=\(afterCreate.count))"
            )
        }

        let renameEntry = try db.fetchAllOutboxEntries()[0]
        do {
            _ = try await remote.ensureRenamed(try SyncOutboxPushService.folder(from: renameEntry))
        } catch {
            return Result(passed: false, message: "RENAME failed: \(Self.describe(error))")
        }
        try db.markOutboxSent(operationId: renameEntry.id)

        let afterRename: [LiveFolderProbe] = try await client
            .from("drawing_folders")
            .select("id,name,deleted_at")
            .eq("id", value: folderId.uuidString)
            .execute()
            .value
        guard afterRename.count == 1, afterRename[0].name == renameName else {
            return Result(
                passed: false,
                message: "Rename not visible in Postgres (name=\(afterRename.first?.name ?? "nil"))"
            )
        }

        // Idempotent rename retry before delete.
        _ = try await remote.ensureRenamed(folder)

        let deleteEntry = try db.fetchAllOutboxEntries()[0]
        do {
            _ = try await remote.ensureDeleted(try SyncOutboxPushService.folder(from: deleteEntry))
        } catch {
            return Result(passed: false, message: "DELETE failed: \(Self.describe(error))")
        }
        try db.markOutboxSent(operationId: deleteEntry.id)

        let remaining = try db.fetchAllOutboxEntries()
        guard remaining.isEmpty else {
            return Result(passed: false, message: "Outbox not empty after live lifecycle")
        }

        let afterDelete: [LiveFolderProbe] = try await client
            .from("drawing_folders")
            .select("id,name,deleted_at")
            .eq("id", value: folderId.uuidString)
            .execute()
            .value
        guard afterDelete.count == 1, afterDelete[0].deletedAt != nil else {
            return Result(
                passed: false,
                message: "Expected soft-deleted tombstone with deleted_at set (count=\(afterDelete.count) deleted_at=\(String(describing: afterDelete.first?.deletedAt)))"
            )
        }

        // Normal listings must hide tombstones via deleted_at IS NULL.
        let activeListing: [LiveFolderProbe] = try await client
            .from("drawing_folders")
            .select("id,name,deleted_at")
            .eq("id", value: folderId.uuidString)
            .is("deleted_at", value: nil)
            .execute()
            .value
        guard activeListing.isEmpty else {
            return Result(
                passed: false,
                message: "Soft-deleted folder still appears in active listing"
            )
        }

        let deleteAgain = try await remote.ensureDeleted(folder)
        guard deleteAgain == .alreadyDeleted else {
            return Result(passed: false, message: "Expected alreadyDeleted on second soft-delete")
        }

        return Result(
            passed: true,
            message: "Live create→rename→soft-delete reached Postgres; tombstone kept; outbox empty; id=\(folderId.uuidString)"
        )
    }

    private static func describe(_ error: Error) -> String {
        if let pg = error as? PostgrestError {
            return "code=\(pg.code ?? "?") message=\(pg.message)"
        }
        return error.localizedDescription
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result?
    }
}

private struct LiveProjectInsert: Encodable {
    let name: String
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case ownerId = "owner_id"
    }
}

private struct LiveFolderProbe: Decodable {
    let id: UUID
    let name: String
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case deletedAt = "deleted_at"
    }
}
