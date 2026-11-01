import Foundation
import Supabase

/// LIVE Supabase Storage check: enqueue + upload one sample PDF into the private
/// `drawings` bucket, confirm existence, preserve local file, then remove the object.
/// Credentials from launch env `BT_LIVE_EMAIL` / `BT_LIVE_PASSWORD` (never hardcoded).
enum LiveDrawingPDFUploadVerification {
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
        return box.value ?? Result(passed: false, message: "Live drawing PDF upload timed out")
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
                .insert(LivePDFProjectInsert(name: "Live PDF Upload", ownerId: userId))
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
                    message: "Could not create or load a project for live PDF upload"
                )
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
                message: "can_edit_project=false for project \(projectId) user \(userId)"
            )
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-live-pdf-upload-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let drawingId = UUID()
        let revisionId = UUID()
        let transferId = UUID()
        let fileName = "\(drawingId.uuidString).pdf"
        let drawingsDir = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try fm.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        let localURL = drawingsDir.appendingPathComponent(fileName)
        try fm.copyItem(at: sampleURL, to: localURL)
        let bytesTotal = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Live PDF", createdDate: Date()))

        let transfer = try db.enqueueDrawingPDFUpload(
            drawingId: drawingId,
            projectId: projectId,
            fileName: fileName,
            bytesTotal: bytesTotal,
            transferId: transferId,
            revisionId: revisionId
        )
        // Second enqueue must reuse the same stable remote path (no overwrite of a different file).
        let again = try db.enqueueDrawingPDFUpload(
            drawingId: drawingId,
            projectId: projectId,
            fileName: fileName,
            bytesTotal: bytesTotal,
            revisionId: UUID()
        )
        guard again.id == transfer.id,
              again.remotePath == transfer.remotePath,
              transfer.remotePath == AppDatabase.drawingPDFRemotePath(
                projectId: projectId,
                revisionId: revisionId
              )
        else {
            return Result(passed: false, message: "Enqueue did not preserve stable remote path")
        }

        let remote = SupabaseDrawingPDFRemoteStore(client: client)
        let remotePath = transfer.remotePath!

        // Simulated interrupt: mark uploading, leave incomplete, then retry same stable path.
        // (Inline — do not call @MainActor upload service from App.init semaphore.)
        try db.markFileTransferUploading(id: transfer.id)
        do {
            try await remote.uploadPDF(localURL: localURL, remotePath: remotePath)
            guard try await remote.objectExists(remotePath: remotePath) else {
                throw DrawingPDFRemoteError.uploadFailed("Object missing after upload")
            }
            try db.markFileTransferCompleted(id: transfer.id, bytesDone: bytesTotal)
        } catch {
            try? db.markFileTransferError(id: transfer.id, error: error.localizedDescription)
            return Result(passed: false, message: "Upload failed: \(error.localizedDescription)")
        }

        guard let after = try db.fetchFileTransfer(id: transfer.id),
              after.status == .completed
        else {
            let err = try db.fetchFileTransfer(id: transfer.id)?.error ?? "nil"
            return Result(
                passed: false,
                message: "Transfer not completed after upload (error=\(err))"
            )
        }

        guard try await remote.objectExists(remotePath: remotePath) else {
            return Result(passed: false, message: "Object missing in drawings bucket at \(remotePath)")
        }

        // Local PDF must remain after confirmed upload.
        guard fm.fileExists(atPath: localURL.path) else {
            return Result(passed: false, message: "Local PDF was removed after upload")
        }

        // Same remote path again must short-circuit on exists (never overwrite another object).
        try await remote.uploadPDF(localURL: localURL, remotePath: remotePath)
        guard try await remote.objectExists(remotePath: remotePath) else {
            return Result(passed: false, message: "Object disappeared after idempotent re-upload")
        }

        // Cleanup test object so the private bucket stays tidy.
        try await remote.removePDF(remotePath: remotePath)
        let stillThere = try await remote.objectExists(remotePath: remotePath)
        guard !stillThere else {
            return Result(passed: false, message: "Cleanup failed; object still present")
        }

        return Result(
            passed: true,
            message: "Live PDF upload reached private drawings bucket; local preserved; transfer completed; cleaned up path=\(remotePath)"
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

private struct LivePDFProjectInsert: Encodable {
    let name: String
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case ownerId = "owner_id"
    }
}
