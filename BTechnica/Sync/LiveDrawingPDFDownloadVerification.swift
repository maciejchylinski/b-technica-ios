// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import PDFKit
import Supabase

/// LIVE check: remote drawing PDF → on-demand download → PDFKit opens → reopen from disk
/// (offline reuse). Credentials: `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD`.
enum LiveDrawingPDFDownloadVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
    }

    static func run() -> Result {
        let box = ResultBox()
        // App.init runs on the main thread; pump the run loop so @MainActor / URLSession
        // callbacks can finish (a blocking semaphore would deadlock download completion).
        Task { @MainActor in
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
        }
        let deadline = Date().addingTimeInterval(120)
        while box.value == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.value ?? Result(passed: false, message: "Live drawing PDF download timed out")
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
                .insert(LivePDFDownloadProjectInsert(name: "Live PDF Download", ownerId: userId))
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
            .appendingPathComponent("btechnica-live-drawing-pdf-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let drawingId = UUID()
        let revisionId = UUID()
        let transferId = UUID()
        let fileName = "\(drawingId.uuidString).pdf"
        let storagePath = AppDatabase.drawingPDFRemotePath(
            projectId: projectId,
            revisionId: revisionId
        )
        let pageCount = PDFDocument(url: sampleURL)?.pageCount ?? 1

        // Upload sample to private Storage (source of truth for the download).
        let pdfRemote = SupabaseDrawingPDFRemoteStore(client: client)
        try await pdfRemote.uploadPDF(localURL: sampleURL, remotePath: storagePath)
        guard try await pdfRemote.objectExists(remotePath: storagePath) else {
            return Result(passed: false, message: "Upload missing before download test")
        }

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live PDF DL", createdDate: Date()))

        // Metadata only — no local PDF bytes yet (mirrors post-pull state).
        let drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: nil,
            name: "Live Download Sample",
            fileName: fileName,
            pageCount: pageCount
        )
        try await db.dbQueue.write { conn in
            try AppDatabase.upsertDrawingsAndCalibrations([drawing], db: conn)
        }
        try await db.dbQueue.write { conn in
            try AppDatabase.upsertPendingDrawingPDFDownload(
                drawingId: drawingId,
                projectId: projectId,
                fileName: fileName,
                remotePath: storagePath,
                transferId: transferId,
                db: conn
            )
        }

        let localURL = root.appendingPathComponent(
            AppDatabase.drawingPDFLocalRelativePath(projectId: projectId, fileName: fileName)
        )
        guard !fm.fileExists(atPath: localURL.path) else {
            return Result(passed: false, message: "Local PDF unexpectedly present before download")
        }

        // 1) Stream download to project Drawings path.
        try await pdfRemote.downloadPDF(remotePath: storagePath, to: localURL)
        guard fm.fileExists(atPath: localURL.path) else {
            return Result(passed: false, message: "Local PDF missing after download")
        }
        try db.markFileTransferCompleted(
            id: transferId,
            bytesDone: (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
        )
        guard let transfer = try db.fetchDrawingPDFDownload(drawingId: drawingId),
              transfer.status == .completed,
              transfer.remotePath == storagePath
        else {
            return Result(passed: false, message: "Download transfer not marked completed")
        }

        // 2) PDFKit opens the downloaded file.
        guard let document = PDFDocument(url: localURL), document.pageCount == pageCount else {
            return Result(passed: false, message: "PDFKit failed to open downloaded PDF")
        }

        // 3) Preserve existing local PDF — second download must not overwrite / must succeed.
        let firstSize = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
        try await pdfRemote.downloadPDF(remotePath: storagePath, to: localURL)
        let secondSize = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
        guard firstSize == secondSize else {
            return Result(passed: false, message: "Re-download changed existing local PDF")
        }

        // 4) Offline reopen: open from disk without another Storage round-trip.
        guard let offline = PDFDocument(url: localURL), offline.pageCount == pageCount else {
            return Result(passed: false, message: "Offline reopen via PDFKit failed")
        }

        // Service path (file already present → confirms local + completed without re-fetch).
        let serviceOK = await DrawingPDFDownloadService.shared.download(
            drawingId: drawingId,
            userId: userId,
            projectId: projectId,
            remote: pdfRemote,
            database: db,
            userRootURL: root
        )
        guard serviceOK else {
            return Result(passed: false, message: "Download service did not confirm local file")
        }

        try? await pdfRemote.removePDF(remotePath: storagePath)

        return Result(
            passed: true,
            message: "Live PDF download OK drawing=\(drawingId.uuidString) pages=\(pageCount) path=\(storagePath)"
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

private struct LivePDFDownloadProjectInsert: Encodable {
    let name: String
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case ownerId = "owner_id"
    }
}
#endif
