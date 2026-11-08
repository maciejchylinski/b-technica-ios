// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import PDFKit
import Supabase

/// LIVE check: sample PDF → private Storage → drawings / drawing_revisions / drawing_pages.
/// Credentials: `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD`. Inline remotes (no @MainActor drain from App.init).
enum LiveDrawingMetadataSyncVerification {
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
                } else if let storage = error as? StorageError {
                    detail = "status=\(storage.statusCode ?? "?") message=\(storage.message)"
                }
                box.value = Result(passed: false, message: "Threw: \(detail)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return box.value ?? Result(passed: false, message: "Live drawing metadata sync timed out")
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
        guard let sampleURL = bundleSamplePDFURL() else {
            return Result(passed: false, message: "Bundled sample PDF not found")
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

        let projectId: UUID
        if let existing = projects.first {
            projectId = existing.id
        } else {
            try await client
                .from("projects")
                .insert(LiveMetaProjectInsert(name: "Live Drawing Meta", ownerId: userId))
                .execute()
            let refreshed: [CloudProject] = try await client
                .from("projects")
                .select("id,name,owner_id,created_at")
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            guard let created = refreshed.first else {
                return Result(passed: false, message: "Could not create/load project")
            }
            projectId = created.id
        }

        struct CanEditParams: Encodable { let p_project_id: UUID }
        let canEdit: Bool = try await client
            .rpc("can_edit_project", params: CanEditParams(p_project_id: projectId))
            .execute()
            .value
        guard canEdit else {
            return Result(
                passed: false,
                message: "can_edit_project=false for project \(projectId)"
            )
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-live-drawing-meta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let drawingId = UUID()
        let revisionId = UUID()
        let transferId = UUID()
        let folderId = UUID()
        let fileName = "\(drawingId.uuidString).pdf"
        let pageCount: Int

        let drawingsDir = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try fm.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        let localURL = drawingsDir.appendingPathComponent(fileName)
        try fm.copyItem(at: sampleURL, to: localURL)
        pageCount = PDFDocument(url: localURL)?.pageCount ?? 0
        let bytesTotal = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live Meta", createdDate: Date()))

        let folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "BT Live Drawings \(Int(Date().timeIntervalSince1970))",
            sortOrder: 0,
            createdDate: Date()
        )
        try db.persistDrawingFolderCreate(folder)

        let drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: "Live Meta Sample",
            fileName: fileName,
            pageCount: pageCount
        )
        try db.replaceFoldersAndDrawings(
            project: Project(id: projectId, name: "Live Meta", createdDate: Date()),
            folders: [folder],
            drawings: [drawing]
        )

        let storagePath = AppDatabase.drawingPDFRemotePath(
            projectId: projectId,
            revisionId: revisionId
        )
        _ = try db.enqueueDrawingPDFUpload(
            drawingId: drawingId,
            projectId: projectId,
            fileName: fileName,
            bytesTotal: bytesTotal,
            transferId: transferId,
            revisionId: revisionId
        )

        let folderRemote = SupabaseDrawingFolderRemoteStore(client: client)
        let pdfRemote = SupabaseDrawingPDFRemoteStore(client: client)
        let drawingRemote = SupabaseDrawingRemoteStore(client: client)

        // Parent folder must exist remotely before drawing.folder_id link.
        _ = try await folderRemote.ensureCreated(folder)

        // 1) Upload PDF to private drawings bucket.
        try await pdfRemote.uploadPDF(localURL: localURL, remotePath: storagePath)
        guard try await pdfRemote.objectExists(remotePath: storagePath) else {
            return Result(passed: false, message: "PDF missing in Storage after upload")
        }
        try db.markFileTransferCompleted(id: transferId, bytesDone: bytesTotal)

        // 2) Metadata only after confirmed upload.
        let enqueued = try db.enqueueDrawingMetadataSyncIfNeeded(drawingId: drawingId)
        guard enqueued else {
            return Result(passed: false, message: "Expected drawing metadata outbox enqueue")
        }
        // Must not enqueue again while pending / before push marker.
        guard try db.enqueueDrawingMetadataSyncIfNeeded(drawingId: drawingId) == false else {
            return Result(passed: false, message: "Duplicate metadata enqueue")
        }

        let entries = try db.fetchAllOutboxEntries().filter { $0.entityType == .drawing }
        guard let metaEntry = entries.first else {
            return Result(passed: false, message: "Drawing outbox entry missing")
        }
        let payload = try SyncOutboxPushService.drawingPayload(from: metaEntry)
        guard payload.revisionId == revisionId, payload.storagePath == storagePath else {
            return Result(passed: false, message: "Payload revision/path mismatch vs Storage")
        }

        // Ensure folder again (idempotent), then drawing/revision/pages.
        _ = try await folderRemote.ensureCreated(folder)
        let created = try await drawingRemote.ensureCreated(payload)
        guard created == .created || created == .alreadyPresent else {
            return Result(passed: false, message: "Unexpected ensureCreated result")
        }
        // Idempotent retry must not overwrite.
        let again = try await drawingRemote.ensureCreated(payload)
        guard again == .alreadyPresent else {
            return Result(passed: false, message: "Expected alreadyPresent on metadata retry")
        }

        try db.markDrawingMetadataPushed(drawingId: drawingId, revisionId: revisionId)
        try db.markOutboxSent(operationId: metaEntry.id)

        // 3) Confirm Postgres rows.
        let drawings: [LiveDrawingProbe] = try await client
            .from("drawings")
            .select("id,project_id,folder_id,name,deleted_at")
            .eq("id", value: drawingId.uuidString)
            .is("deleted_at", value: nil)
            .execute()
            .value
        guard drawings.count == 1,
              drawings[0].projectId == projectId,
              drawings[0].folderId == folderId,
              drawings[0].name == drawing.name
        else {
            return Result(passed: false, message: "Drawing row missing or mismatched in Postgres")
        }

        let revisions: [LiveRevisionProbe] = try await client
            .from("drawing_revisions")
            .select("id,drawing_id,storage_path,page_count,is_current,deleted_at")
            .eq("id", value: revisionId.uuidString)
            .is("deleted_at", value: nil)
            .execute()
            .value
        guard revisions.count == 1,
              revisions[0].drawingId == drawingId,
              revisions[0].storagePath == storagePath,
              revisions[0].pageCount == pageCount,
              revisions[0].isCurrent
        else {
            return Result(passed: false, message: "Revision row missing or mismatched in Postgres")
        }

        let pages: [LivePageProbe] = try await client
            .from("drawing_pages")
            .select("id,revision_id,page_index,deleted_at")
            .eq("revision_id", value: revisionId.uuidString)
            .is("deleted_at", value: nil)
            .order("page_index", ascending: true)
            .execute()
            .value
        let pageIndexes = pages.map(\.pageIndex)
        guard pageIndexes == Array(0..<pageCount) else {
            return Result(
                passed: false,
                message: "Pages mismatch expected 0..<\(pageCount) got \(pageIndexes)"
            )
        }

        // Local PDF preserved; Storage object still present.
        guard fm.fileExists(atPath: localURL.path) else {
            return Result(passed: false, message: "Local PDF was removed")
        }
        guard try await pdfRemote.objectExists(remotePath: storagePath) else {
            return Result(passed: false, message: "Storage object missing after metadata sync")
        }

        // Cleanup remote test data (drawing cascades revision/pages).
        try await client
            .from("drawings")
            .delete()
            .eq("id", value: drawingId.uuidString)
            .execute()
        try await folderRemote.ensureDeleted(folder)
        try await pdfRemote.removePDF(remotePath: storagePath)

        return Result(
            passed: true,
            message: "Live PDF+metadata sync OK drawing=\(drawingId.uuidString) revision=\(revisionId.uuidString) pages=\(pageCount) path=\(storagePath)"
        )
    }

    private static func bundleSamplePDFURL() -> URL? {
        for subdirectory in ["Resources/SampleDrawings", "SampleDrawings", nil] {
            if let url = Bundle.main.url(
                forResource: "sample-apartment",
                withExtension: "pdf",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return Bundle.main.url(forResource: "sample-apartment", withExtension: "pdf")
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result?
    }
}

private struct LiveMetaProjectInsert: Encodable {
    let name: String
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case ownerId = "owner_id"
    }
}

private struct LiveDrawingProbe: Decodable {
    let id: UUID
    let projectId: UUID
    let folderId: UUID?
    let name: String
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case folderId = "folder_id"
        case name
        case deletedAt = "deleted_at"
    }
}

private struct LiveRevisionProbe: Decodable {
    let id: UUID
    let drawingId: UUID
    let storagePath: String
    let pageCount: Int
    let isCurrent: Bool
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case drawingId = "drawing_id"
        case storagePath = "storage_path"
        case pageCount = "page_count"
        case isCurrent = "is_current"
        case deletedAt = "deleted_at"
    }
}

private struct LivePageProbe: Decodable {
    let id: UUID
    let revisionId: UUID
    let pageIndex: Int
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case revisionId = "revision_id"
        case pageIndex = "page_index"
        case deletedAt = "deleted_at"
    }
}
#endif
