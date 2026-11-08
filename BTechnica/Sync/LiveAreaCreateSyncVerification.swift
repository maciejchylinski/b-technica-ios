// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import PDFKit
import Supabase

/// LIVE check: create local area → resolve page mapping → sync to Supabase `areas`.
/// Confirms UUID, drawing_page_id, and PDF vertices. Credentials: `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD`.
enum LiveAreaCreateSyncVerification {
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
        _ = semaphore.wait(timeout: .now() + 180)
        return box.value ?? Result(passed: false, message: "Live area create sync timed out")
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
            return Result(passed: false, message: "No project available for live area sync")
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
            .appendingPathComponent("btechnica-live-area-create-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stamp = Int(Date().timeIntervalSince1970)
        let folderId = UUID()
        let drawingId = UUID()
        let revisionId = UUID()
        let transferId = UUID()
        let areaId = UUID()
        let fileName = "\(drawingId.uuidString).pdf"
        let storagePath = AppDatabase.drawingPDFRemotePath(projectId: projectId, revisionId: revisionId)

        let drawingsDir = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try fm.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        let localURL = drawingsDir.appendingPathComponent(fileName)
        try fm.copyItem(at: sampleURL, to: localURL)
        let pageCount = PDFDocument(url: localURL)?.pageCount ?? 1
        let bytesTotal = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live Area", createdDate: Date()))

        let folderRemote = SupabaseDrawingFolderRemoteStore(client: client)
        let pdfRemote = SupabaseDrawingPDFRemoteStore(client: client)
        let drawingRemote = SupabaseDrawingRemoteStore(client: client)
        let areaRemote = SupabaseAreaRemoteStore(client: client)

        let folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "BT Live Areas \(stamp)",
            sortOrder: 0,
            createdDate: Date()
        )
        try db.persistDrawingFolderCreate(folder)
        _ = try await folderRemote.ensureCreated(folder)

        let drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: "BT Live Area Drawing \(stamp)",
            fileName: fileName,
            pageCount: pageCount
        )
        try db.replaceFoldersAndDrawings(
            project: Project(id: projectId, name: "Live Area", createdDate: Date()),
            folders: [folder],
            drawings: [drawing]
        )

        _ = try db.enqueueDrawingPDFUpload(
            drawingId: drawingId,
            projectId: projectId,
            fileName: fileName,
            bytesTotal: bytesTotal,
            transferId: transferId,
            revisionId: revisionId
        )
        try await pdfRemote.uploadPDF(localURL: localURL, remotePath: storagePath)
        try db.markFileTransferCompleted(id: transferId, bytesDone: bytesTotal)

        let payload = DrawingMetadataPayload(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: drawing.name,
            fileName: fileName,
            pageCount: pageCount,
            createdDate: drawing.createdDate,
            revisionLabel: nil,
            discipline: nil,
            location: nil,
            drawingDate: nil,
            revisionId: revisionId,
            storagePath: storagePath
        )
        _ = try await drawingRemote.ensureCreated(payload)
        let pages = try await drawingRemote.fetchRevisionPages(revisionId: revisionId)
        guard !pages.isEmpty else {
            return Result(passed: false, message: "No remote drawing_pages after metadata ensure")
        }
        try db.replaceDrawingPageMappings(
            projectId: projectId,
            drawingId: drawingId,
            revisionId: revisionId,
            pages: pages
        )
        try db.markDrawingMetadataPushed(drawingId: drawingId, revisionId: revisionId)

        // Area created while drawing not ready stays pending in outbox.
        let earlyArea = Area(
            id: UUID(),
            projectId: projectId,
            drawingId: UUID(),
            pageIndex: 0,
            name: "Pending Area",
            vertices: [
                PDFPoint(x: 0, y: 0),
                PDFPoint(x: 10, y: 0),
                PDFPoint(x: 5, y: 10)
            ]
        )
        // Use a throwaway DB row only for pending-path check on a known unsynced drawing id.
        let unsyncedDrawingId = UUID()
        try db.replaceFoldersAndDrawings(
            project: Project(id: projectId, name: "Live Area", createdDate: Date()),
            folders: [folder],
            drawings: [
                drawing,
                Drawing(
                    id: unsyncedDrawingId,
                    projectId: projectId,
                    folderId: folderId,
                    name: "Unsynced",
                    fileName: "\(unsyncedDrawingId.uuidString).pdf",
                    pageCount: 1
                )
            ]
        )
        let pendingArea = Area(
            id: earlyArea.id,
            projectId: projectId,
            drawingId: unsyncedDrawingId,
            pageIndex: 0,
            name: "Pending Area",
            vertices: earlyArea.vertices
        )
        try db.persistAreaCreate(pendingArea)
        guard let pendingEntry = try db.fetchAllOutboxEntries().first(where: {
            $0.entityType == .area && $0.entityId == pendingArea.id
        }) else {
            return Result(passed: false, message: "Pending area outbox entry missing")
        }
        // Simulate drain deferral: no revision → keep pending.
        guard try db.syncedDrawingRevisionId(drawingId: unsyncedDrawingId) == nil else {
            return Result(passed: false, message: "Unsynced drawing unexpectedly has revision marker")
        }
        try db.markOutboxError(
            operationId: pendingEntry.id,
            error: AreaRemoteError.notReady("Drawing metadata not synced").localizedDescription,
            nextAttemptAt: Date().addingTimeInterval(60)
        )
        guard try db.fetchAllOutboxEntries().contains(where: { $0.id == pendingEntry.id }) else {
            return Result(passed: false, message: "Pending area outbox was dropped")
        }

        let vertices = [
            PDFPoint(x: 100.5, y: 200.25),
            PDFPoint(x: 300.0, y: 200.25),
            PDFPoint(x: 200.0, y: 400.5)
        ]
        let area = Area(
            id: areaId,
            projectId: projectId,
            drawingId: drawingId,
            pageIndex: 0,
            name: "BT Live Polygon \(stamp)",
            vertices: vertices,
            color: "#FF3B30",
            opacity: 0.4,
            isVisible: true
        )
        try db.persistAreaCreate(area)
        // Idempotent second call must not duplicate outbox.
        try db.persistAreaCreate(area)
        let areaOps = try db.fetchAllOutboxEntries().filter {
            $0.entityType == .area && $0.entityId == areaId
        }
        guard areaOps.count == 1, let areaEntry = areaOps.first else {
            return Result(passed: false, message: "Expected exactly one area create outbox row")
        }

        let pageId = try db.resolveDrawingPageId(
            revisionId: revisionId,
            pageIndex: 0,
            projectId: projectId,
            drawingId: drawingId
        )
        let createPayload = AreaCreatePayload(
            id: area.id,
            projectId: area.projectId,
            drawingId: area.drawingId,
            pageId: pageId,
            name: area.name,
            vertices: area.vertices,
            color: area.color,
            opacity: area.opacity,
            isVisible: area.isVisible,
            createdDate: area.createdDate,
            updatedDate: area.updatedDate
        )
        let created = try await areaRemote.ensureCreated(createPayload)
        guard created == .created || created == .alreadyPresent else {
            return Result(passed: false, message: "Unexpected area ensureCreated result")
        }
        let again = try await areaRemote.ensureCreated(createPayload)
        guard again == .alreadyPresent else {
            return Result(passed: false, message: "Expected alreadyPresent on area retry")
        }
        try db.markAreaCreatePushed(areaId: areaId)
        try db.markOutboxSent(operationId: areaEntry.id)

        let remoteAreas: [LiveAreaProbe] = try await client
            .from("areas")
            .select("id,project_id,drawing_id,page_id,name,vertices,color,opacity,is_visible,deleted_at")
            .eq("id", value: areaId.uuidString)
            .is("deleted_at", value: nil)
            .execute()
            .value
        guard let remote = remoteAreas.first else {
            return Result(passed: false, message: "Area row missing in Postgres")
        }
        guard remote.projectId == projectId,
              remote.drawingId == drawingId,
              remote.pageId == pageId,
              remote.name == area.name,
              remote.color == area.color,
              abs(remote.opacity - area.opacity) < 0.000_1,
              remote.isVisible == true
        else {
            return Result(
                passed: false,
                message: "Area fields mismatch remote page=\(remote.pageId) expected=\(pageId)"
            )
        }
        guard remote.vertices.count == vertices.count else {
            return Result(passed: false, message: "Vertex count mismatch")
        }
        for (lhs, rhs) in zip(remote.vertices, vertices) {
            guard abs(lhs.x - rhs.x) < 0.000_1, abs(lhs.y - rhs.y) < 0.000_1 else {
                return Result(passed: false, message: "Vertex coordinate mismatch")
            }
        }

        // Local issue→area link still resolvable (editing path preserved).
        let localAreas = try db.fetchAreas(projectId: projectId)
        guard localAreas.contains(where: { $0.id == areaId && $0.vertices.count == 3 }) else {
            return Result(passed: false, message: "Local area UUID/vertices not preserved")
        }

        // Cleanup remote test data.
        try await client.from("areas").delete().eq("id", value: areaId.uuidString).execute()
        try await client.from("drawings").delete().eq("id", value: drawingId.uuidString).execute()
        try await folderRemote.ensureDeleted(folder)
        try await pdfRemote.removePDF(remotePath: storagePath)

        return Result(
            passed: true,
            message: "Live area create OK area=\(areaId.uuidString) page=\(pageId.uuidString) vertices=\(vertices.count)"
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

private struct LiveAreaProbe: Decodable {
    let id: UUID
    let projectId: UUID
    let drawingId: UUID
    let pageId: UUID
    let name: String
    let vertices: [LiveVertex]
    let color: String
    let opacity: Double
    let isVisible: Bool
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case drawingId = "drawing_id"
        case pageId = "page_id"
        case name
        case vertices
        case color
        case opacity
        case isVisible = "is_visible"
        case deletedAt = "deleted_at"
    }
}

private struct LiveVertex: Decodable {
    let x: Double
    let y: Double
}
#endif
