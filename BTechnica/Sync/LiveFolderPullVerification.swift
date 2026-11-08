// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import Supabase

/// LIVE check: remote create → pull → local visible; remote rename/tombstone; pending outbox skipped;
/// local-only folder retained. Credentials: `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD`.
enum LiveFolderPullVerification {
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
                    detail = "code=\(pg.code ?? "?") message=\(pg.message)"
                }
                box.value = Result(passed: false, message: "Threw: \(detail)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 90)
        return box.value ?? Result(passed: false, message: "Live folder pull timed out")
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
        guard let projectId = projects.first?.id else {
            return Result(passed: false, message: "No project available for live folder pull")
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-live-folder-pull-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live Pull", createdDate: Date()))

        let remote = SupabaseDrawingFolderRemoteStore(client: client)
        let stamp = Int(Date().timeIntervalSince1970)
        let folderId = UUID()
        let createName = "BT Pull \(stamp)"
        let remoteRenameName = "BT Pull Remote \(stamp)"
        let pendingLocalName = "BT Pull Pending \(stamp)"
        let localOnlyId = UUID()

        // Local-only folder must survive pull (absent remotely).
        try seedLocalOnly(
            db: db,
            folder: DrawingFolder(
                id: localOnlyId,
                projectId: projectId,
                parentFolderId: nil,
                name: "Local Only \(stamp)",
                sortOrder: 0,
                createdDate: Date()
            )
        )

        // Remote create (not via outbox) so pull is the path that inserts locally.
        let remoteFolder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: createName,
            sortOrder: 0,
            createdDate: Date()
        )
        _ = try await remote.ensureCreated(remoteFolder)

        let pulled = try await remote.fetchProjectFolders(projectId: projectId)
        _ = try db.applyRemoteDrawingFolderPull(projectId: projectId, remoteFolders: pulled)
        var local = try db.fetchDrawingFolders(projectId: projectId)
        guard local.contains(where: { $0.id == folderId && $0.name == createName }) else {
            return Result(passed: false, message: "Pulled create not visible locally")
        }
        guard local.contains(where: { $0.id == localOnlyId }) else {
            return Result(passed: false, message: "Local-only folder was deleted by pull")
        }

        // Idempotent second pull — no duplicates.
        let beforeCount = local.count
        _ = try db.applyRemoteDrawingFolderPull(projectId: projectId, remoteFolders: pulled)
        local = try db.fetchDrawingFolders(projectId: projectId)
        guard local.count == beforeCount else {
            return Result(
                passed: false,
                message: "Repeated pull changed folder count \(beforeCount)→\(local.count)"
            )
        }
        guard try db.fetchAllOutboxEntries().isEmpty else {
            return Result(passed: false, message: "Pull enqueued unexpected outbox ops")
        }

        // Pending local rename must win over a concurrent remote rename.
        var pendingLocal = remoteFolder
        pendingLocal.name = pendingLocalName
        let pendingOp = UUID()
        try db.persistDrawingFolderRename(pendingLocal, operationId: pendingOp)

        var remoteRenamed = remoteFolder
        remoteRenamed.name = remoteRenameName
        _ = try await remote.ensureRenamed(remoteRenamed)

        let afterRemoteRename = try await remote.fetchProjectFolders(projectId: projectId)
        let applyPending = try db.applyRemoteDrawingFolderPull(
            projectId: projectId,
            remoteFolders: afterRemoteRename
        )
        local = try db.fetchDrawingFolders(projectId: projectId)
        guard local.contains(where: { $0.id == folderId && $0.name == pendingLocalName }) else {
            return Result(passed: false, message: "Pending outbox rename was overwritten by pull")
        }
        guard applyPending.skippedPending >= 1 else {
            return Result(passed: false, message: "Expected skippedPending for outbox folder")
        }

        // Clear pending op, pull again → remote rename applies.
        try db.markOutboxSent(operationId: pendingOp)
        let afterClear = try await remote.fetchProjectFolders(projectId: projectId)
        _ = try db.applyRemoteDrawingFolderPull(projectId: projectId, remoteFolders: afterClear)
        local = try db.fetchDrawingFolders(projectId: projectId)
        guard local.contains(where: { $0.id == folderId && $0.name == remoteRenameName }) else {
            return Result(passed: false, message: "Remote rename not applied after outbox cleared")
        }

        // Soft-delete tombstone → local hard-delete of that id only.
        _ = try await remote.ensureDeleted(remoteRenamed)
        let afterRemoteDelete = try await remote.fetchProjectFolders(projectId: projectId)
        guard afterRemoteDelete.contains(where: { $0.id == folderId && $0.deletedAt != nil }) else {
            return Result(passed: false, message: "Remote tombstone missing after soft-delete")
        }
        let applyDelete = try db.applyRemoteDrawingFolderPull(
            projectId: projectId,
            remoteFolders: afterRemoteDelete
        )
        local = try db.fetchDrawingFolders(projectId: projectId)
        guard !local.contains(where: { $0.id == folderId }) else {
            return Result(passed: false, message: "Tombstone did not remove local folder")
        }
        guard local.contains(where: { $0.id == localOnlyId }) else {
            return Result(passed: false, message: "Local-only folder lost after tombstone pull")
        }
        guard applyDelete.removed >= 1 else {
            return Result(passed: false, message: "Expected removed >= 1 for tombstone apply")
        }
        guard try db.fetchAllOutboxEntries().isEmpty else {
            return Result(passed: false, message: "Outbox not empty after tombstone pull")
        }

        return Result(
            passed: true,
            message: "Live pull create/rename/tombstone ok; local-only kept; pending skipped; id=\(folderId.uuidString)"
        )
    }

    /// Upsert without outbox (local-only seed).
    private static func seedLocalOnly(db: AppDatabase, folder: DrawingFolder) throws {
        try db.applyRemoteDrawingFolderPull(
            projectId: folder.projectId,
            remoteFolders: [
                RemoteDrawingFolder(
                    id: folder.id,
                    projectId: folder.projectId,
                    parentFolderId: folder.parentFolderId,
                    name: folder.name,
                    sortOrder: folder.sortOrder,
                    createdAt: folder.createdDate,
                    deletedAt: nil
                )
            ]
        )
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result?
    }
}
#endif
