// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import PDFKit
import Supabase

/// LIVE check: remote drawing metadata → SQLite pull; idempotent; pending skipped;
/// local-only retained; issue/area refs preserved; PDF path stored without local availability.
/// Credentials: `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD`.
enum LiveDrawingMetadataPullVerification {
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
                let stepPrefix: String
                let underlying: Error
                if let labeled = error as? LivePullStepError {
                    stepPrefix = "step=\(labeled.step) "
                    underlying = labeled.underlying
                } else {
                    stepPrefix = ""
                    underlying = error
                }
                var detail = underlying.localizedDescription
                if let pg = underlying as? PostgrestError {
                    detail = "code=\(pg.code ?? "?") message=\(pg.message) details=\(pg.details ?? "nil")"
                } else if let storage = underlying as? StorageError {
                    detail = "status=\(storage.statusCode ?? "?") message=\(storage.message)"
                }
                box.value = Result(passed: false, message: "Threw: \(stepPrefix)\(detail)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return box.value ?? Result(passed: false, message: "Live drawing metadata pull timed out")
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
        guard let projectId = projects.first?.id else {
            return Result(passed: false, message: "No project available for live drawing pull")
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
            .appendingPathComponent("btechnica-live-drawing-pull-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stamp = Int(Date().timeIntervalSince1970)
        let folderId = UUID()
        let drawingId = UUID()
        let revisionId = UUID()
        let localOnlyId = UUID()
        let pendingId = UUID()
        let pendingRevisionId = UUID()
        let pendingOp = UUID()
        let protectedId = UUID()
        let protectedRevisionId = UUID()
        let issueId = UUID()
        let fileName = "\(drawingId.uuidString).pdf"
        let remoteName = "BT Pull Draw \(stamp)"
        let pendingLocalName = "BT Pull Pending Local \(stamp)"
        let pendingRemoteName = "BT Pull Pending Remote \(stamp)"
        let storagePath = AppDatabase.drawingPDFRemotePath(projectId: projectId, revisionId: revisionId)
        let pendingPath = AppDatabase.drawingPDFRemotePath(
            projectId: projectId,
            revisionId: pendingRevisionId
        )
        let protectedPath = AppDatabase.drawingPDFRemotePath(
            projectId: projectId,
            revisionId: protectedRevisionId
        )

        let drawingsDir = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try fm.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        let uploadURL = drawingsDir.appendingPathComponent("upload-\(fileName)")
        try fm.copyItem(at: sampleURL, to: uploadURL)
        let pageCount = PDFDocument(url: uploadURL)?.pageCount ?? 1

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live Drawing Pull", createdDate: Date()))

        let folderRemote = SupabaseDrawingFolderRemoteStore(client: client)
        let pdfRemote = SupabaseDrawingPDFRemoteStore(client: client)
        let drawingRemote = SupabaseDrawingRemoteStore(client: client)

        let folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "BT Pull Drawings \(stamp)",
            sortOrder: 0,
            createdDate: Date()
        )
        // Mirror push LIVE verify: local persist then remote ensure.
        try db.persistDrawingFolderCreate(folder)
        do {
            _ = try await folderRemote.ensureCreated(folder)
        } catch {
            throw LivePullStepError(step: "folder.ensureCreated", underlying: error)
        }
        // Folder is already remote; clear setup outbox so pull assertions stay focused on drawings.
        for entry in try db.fetchAllOutboxEntries() where entry.entityType == .drawingFolder {
            try db.markOutboxSent(operationId: entry.id)
        }

        // Local-only drawing must survive pull (absent remotely).
        try await seedLocalDrawing(
            db: db,
            drawing: Drawing(
                id: localOnlyId,
                projectId: projectId,
                folderId: folderId,
                name: "Local Only Draw \(stamp)",
                fileName: "\(localOnlyId.uuidString).pdf",
                pageCount: 1
            )
        )

        // Seed remote create (folder + PDF + metadata) — pull is the local insert path.
        do {
            try await pdfRemote.uploadPDF(localURL: uploadURL, remotePath: storagePath)
        } catch {
            throw LivePullStepError(step: "pdf.upload.main", underlying: error)
        }
        let payload = DrawingMetadataPayload(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: remoteName,
            fileName: fileName,
            pageCount: pageCount,
            createdDate: Date(),
            revisionLabel: "A",
            discipline: "Architectural",
            location: "Level 1",
            drawingDate: nil,
            revisionId: revisionId,
            storagePath: storagePath
        )
        do {
            _ = try await drawingRemote.ensureCreated(payload)
        } catch {
            throw LivePullStepError(step: "drawing.ensureCreated.main", underlying: error)
        }

        // Remote pending-conflict drawing (different remote name than local pending).
        do {
            try await pdfRemote.uploadPDF(localURL: uploadURL, remotePath: pendingPath)
            let pendingRemotePayload = DrawingMetadataPayload(
                id: pendingId,
                projectId: projectId,
                folderId: folderId,
                name: pendingRemoteName,
                fileName: "\(pendingId.uuidString).pdf",
                pageCount: pageCount,
                createdDate: Date(),
                revisionLabel: nil,
                discipline: nil,
                location: nil,
                drawingDate: nil,
                revisionId: pendingRevisionId,
                storagePath: pendingPath
            )
            _ = try await drawingRemote.ensureCreated(pendingRemotePayload)
        } catch {
            throw LivePullStepError(step: "drawing.ensureCreated.pending", underlying: error)
        }

        // Local pending outbox must win over remote name.
        try await seedLocalDrawing(
            db: db,
            drawing: Drawing(
                id: pendingId,
                projectId: projectId,
                folderId: folderId,
                name: pendingLocalName,
                fileName: "\(pendingId.uuidString).pdf",
                pageCount: pageCount
            )
        )
        try await db.dbQueue.write { conn in
            try AppDatabase.insertOutboxEntry(
                operationId: pendingOp,
                entityType: .drawing,
                entityId: pendingId,
                operation: .create,
                payloadJSON: nil,
                db: conn
            )
        }

        // Protected tombstone candidate: remote soft-delete later; local issue must block delete.
        do {
            try await pdfRemote.uploadPDF(localURL: uploadURL, remotePath: protectedPath)
            let protectedPayload = DrawingMetadataPayload(
                id: protectedId,
                projectId: projectId,
                folderId: folderId,
                name: "BT Pull Protected \(stamp)",
                fileName: "\(protectedId.uuidString).pdf",
                pageCount: pageCount,
                createdDate: Date(),
                revisionLabel: nil,
                discipline: nil,
                location: nil,
                drawingDate: nil,
                revisionId: protectedRevisionId,
                storagePath: protectedPath
            )
            _ = try await drawingRemote.ensureCreated(protectedPayload)
        } catch {
            throw LivePullStepError(step: "drawing.ensureCreated.protected", underlying: error)
        }

        // 1) Pull create → local visible with remote UUID / folder link.
        let pulled = try await drawingRemote.fetchProjectDrawings(projectId: projectId)
        let apply = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: pulled)
        var local = try db.fetchDrawings(projectId: projectId)
        guard let pulledDrawing = local.first(where: { $0.id == drawingId }) else {
            return Result(passed: false, message: "Pulled drawing not visible locally")
        }
        guard pulledDrawing.folderId == folderId,
              pulledDrawing.name == remoteName,
              pulledDrawing.pageCount == pageCount,
              pulledDrawing.revision == "A"
        else {
            return Result(passed: false, message: "Pulled drawing fields/folder mismatch")
        }
        guard local.contains(where: { $0.id == localOnlyId }) else {
            return Result(passed: false, message: "Local-only drawing was deleted by pull")
        }
        guard local.contains(where: { $0.id == pendingId && $0.name == pendingLocalName }) else {
            return Result(passed: false, message: "Pending outbox drawing was overwritten by pull")
        }
        guard apply.skippedPending >= 1 else {
            return Result(passed: false, message: "Expected skippedPending for outbox drawing")
        }

        // Remote PDF path stored; transfer not completed; no local PDF bytes for pulled drawing.
        guard let download = try db.fetchDrawingPDFDownload(drawingId: drawingId),
              download.remotePath == storagePath,
              download.status == .pending,
              download.direction == .download
        else {
            return Result(passed: false, message: "Expected pending download transfer with remote path")
        }
        let pulledPDFURL = drawingsDir.appendingPathComponent(pulledDrawing.fileName)
        guard !fm.fileExists(atPath: pulledPDFURL.path) else {
            return Result(passed: false, message: "Pull created a local PDF (must stay unavailable)")
        }

        // 2) Idempotent second pull — no duplicates / no outbox from pull.
        let beforeCount = local.count
        _ = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: pulled)
        local = try db.fetchDrawings(projectId: projectId)
        guard local.count == beforeCount else {
            return Result(
                passed: false,
                message: "Repeated pull changed drawing count \(beforeCount)→\(local.count)"
            )
        }
        let drawingOutboxAfterPull = try db.fetchAllOutboxEntries().filter { $0.entityType == .drawing }
        guard drawingOutboxAfterPull.allSatisfy({ $0.id == pendingOp }),
              drawingOutboxAfterPull.count == 1
        else {
            return Result(passed: false, message: "Pull enqueued unexpected drawing outbox ops")
        }

        // 3) Clear pending, pull again → remote name applies.
        try db.markOutboxSent(operationId: pendingOp)
        let afterClear = try await drawingRemote.fetchProjectDrawings(projectId: projectId)
        _ = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: afterClear)
        local = try db.fetchDrawings(projectId: projectId)
        guard local.contains(where: { $0.id == pendingId && $0.name == pendingRemoteName }) else {
            return Result(passed: false, message: "Remote rename not applied after outbox cleared")
        }

        // 4) Issue reference preserved across metadata refresh of same drawing id.
        try await db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO issues
                  (id, project_id, drawing_id, page_index, pdf_x, pdf_y, area_id,
                   number, title, details, status, created_at)
                VALUES (?, ?, ?, 0, 10, 20, NULL, 1, 'Pull Issue', '', 'open', ?)
                """,
                arguments: [
                    issueId.uuidString,
                    projectId.uuidString,
                    drawingId.uuidString,
                    SQLiteDateCoding.string(from: Date())
                ]
            )
        }
        var renamedRemote = payload
        renamedRemote.name = "\(remoteName) Renamed"
        // Push rename via update (ensureCreated won't overwrite); use direct update.
        do {
            try await client
                .from("drawings")
                .update(LiveDrawingNameUpdate(name: renamedRemote.name), returning: .minimal)
                .eq("id", value: drawingId.uuidString)
                .execute()
        } catch {
            throw LivePullStepError(step: "drawing.rename", underlying: error)
        }
        let afterRename = try await drawingRemote.fetchProjectDrawings(projectId: projectId)
        _ = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: afterRename)
        local = try db.fetchDrawings(projectId: projectId)
        guard local.contains(where: { $0.id == drawingId && $0.name == renamedRemote.name }) else {
            return Result(passed: false, message: "Remote drawing rename not applied")
        }
        let issueCount = try await db.dbQueue.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM issues WHERE id = ? AND drawing_id = ?",
                arguments: [issueId.uuidString, drawingId.uuidString]
            ) ?? 0
        }
        guard issueCount == 1 else {
            return Result(passed: false, message: "Issue reference lost after drawing pull upsert")
        }

        // 5) Soft-delete drawing that has a local issue → skippedProtected; issue remains.
        do {
            try await client
                .from("drawings")
                .update(
                    LiveDrawingSoftDelete(deletedAt: SQLiteDateCoding.string(from: Date())),
                    returning: .minimal
                )
                .eq("id", value: drawingId.uuidString)
                .execute()
        } catch {
            throw LivePullStepError(step: "drawing.softDelete.protected", underlying: error)
        }
        let afterProtectedTombstone = try await drawingRemote.fetchProjectDrawings(projectId: projectId)
        let applyProtected = try db.applyRemoteDrawingPull(
            projectId: projectId,
            remoteDrawings: afterProtectedTombstone
        )
        local = try db.fetchDrawings(projectId: projectId)
        guard local.contains(where: { $0.id == drawingId }) else {
            return Result(passed: false, message: "Protected tombstone removed drawing with issues")
        }
        guard applyProtected.skippedProtected >= 1 else {
            return Result(passed: false, message: "Expected skippedProtected for drawing with issues")
        }

        // 6) Soft-delete unprotected remote drawing → local hard-delete of that id only.
        do {
            try await client
                .from("drawings")
                .update(
                    LiveDrawingSoftDelete(deletedAt: SQLiteDateCoding.string(from: Date())),
                    returning: .minimal
                )
                .eq("id", value: protectedId.uuidString)
                .execute()
        } catch {
            throw LivePullStepError(step: "drawing.softDelete.unprotected", underlying: error)
        }
        let afterDelete = try await drawingRemote.fetchProjectDrawings(projectId: projectId)
        let applyDelete = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: afterDelete)
        local = try db.fetchDrawings(projectId: projectId)
        guard !local.contains(where: { $0.id == protectedId }) else {
            return Result(passed: false, message: "Tombstone did not remove unprotected local drawing")
        }
        guard local.contains(where: { $0.id == localOnlyId }) else {
            return Result(passed: false, message: "Local-only drawing lost after tombstone pull")
        }
        guard applyDelete.removed >= 1 else {
            return Result(passed: false, message: "Expected removed >= 1 for unprotected tombstone")
        }

        // Cleanup remote test data (hard-delete drawings cascade revisions/pages).
        for id in [drawingId, pendingId, protectedId] {
            try? await client
                .from("drawings")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
        try? await folderRemote.ensureDeleted(folder)
        for path in [storagePath, pendingPath, protectedPath] {
            try? await pdfRemote.removePDF(remotePath: path)
        }

        return Result(
            passed: true,
            message: "Live drawing pull ok; local-only kept; pending skipped; issue preserved; id=\(drawingId.uuidString)"
        )
    }

    /// Upsert drawing metadata without outbox (local-only / fixture seed).
    private static func seedLocalDrawing(db: AppDatabase, drawing: Drawing) async throws {
        try await db.dbQueue.write { conn in
            try AppDatabase.upsertDrawingsAndCalibrations([drawing], db: conn)
        }
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

private struct LiveDrawingNameUpdate: Encodable {
    let name: String
}

private struct LiveDrawingSoftDelete: Encodable {
    let deletedAt: String

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}

private struct LivePullStepError: Error {
    var step: String
    var underlying: Error
}
#endif
