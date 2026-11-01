import Foundation
import os.log

private let downloadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "DrawingPDFDownload"
)

/// Downloads drawing PDFs from private Storage into the local Drawings directory.
/// Scheduling / cancellation are owned by `DrawingPDFDownloadCoordinator`.
@MainActor
final class DrawingPDFDownloadService {
    static let shared = DrawingPDFDownloadService()

    private init() {}

    /// Downloads one drawing's PDF (on-demand). Returns true when the local file is present
    /// and the transfer is marked completed.
    @discardableResult
    func download(
        drawingId: UUID,
        userId: UUID,
        projectId: UUID,
        remote: DrawingPDFRemoteStore = SupabaseDrawingPDFRemoteStore(),
        database: AppDatabase? = nil,
        userRootURL: URL? = nil
    ) async -> Bool {
        guard SupabaseManager.isConfigured || DrawingPDFDownloadCoordinator.shared.isTestBypassConfigured else {
            return false
        }

        do {
            let db = try database ?? AppDatabase.shared(for: userId)
            let root = userRootURL ?? db.rootURL
            guard let transfer = try db.fetchDrawingPDFDownload(drawingId: drawingId) else {
                downloadLog.error(
                    "No download transfer for drawing=\(drawingId.uuidString, privacy: .public)"
                )
                return false
            }
            let localURL = root.appendingPathComponent(transfer.localRelativePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                if transfer.status != .completed {
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
                        .int64Value
                    try? db.markFileTransferCompleted(id: transfer.id, bytesDone: bytes)
                }
                return true
            }

            let outcome = await process(
                transfer: transfer,
                projectId: projectId,
                database: db,
                remote: remote,
                userRootURL: root
            )
            return outcome == .completed
        } catch {
            downloadLog.error("PDF download failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Retries incomplete downloads for the active project (reconnect / schedule).
    func pullPending(
        userId: UUID,
        projectId: UUID,
        remote: DrawingPDFRemoteStore = SupabaseDrawingPDFRemoteStore(),
        database: AppDatabase? = nil,
        userRootURL: URL? = nil
    ) async {
        guard SupabaseManager.isConfigured || DrawingPDFDownloadCoordinator.shared.isTestBypassConfigured else {
            return
        }

        do {
            let db = try database ?? AppDatabase.shared(for: userId)
            let root = userRootURL ?? db.rootURL
            let transfers = try db.fetchPendingDrawingPDFDownloads(projectId: projectId)
            for transfer in transfers {
                if Task.isCancelled { return }
                let outcome = await process(
                    transfer: transfer,
                    projectId: projectId,
                    database: db,
                    remote: remote,
                    userRootURL: root
                )
                if outcome == .stopDrain { return }
            }
        } catch {
            downloadLog.error("PDF download drain failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Processing

    private enum Step {
        case completed
        case continueDrain
        case stopDrain
    }

    private func process(
        transfer: FileTransfer,
        projectId: UUID,
        database: AppDatabase,
        remote: DrawingPDFRemoteStore,
        userRootURL: URL
    ) async -> Step {
        guard transfer.direction == .download,
              transfer.entityType == .drawing,
              let remotePath = transfer.remotePath,
              !remotePath.isEmpty
        else {
            try? database.markFileTransferError(
                id: transfer.id,
                error: "Invalid drawing PDF download row"
            )
            return .stopDrain
        }

        // Path must belong to this project (remote key prefix).
        let expectedPrefix = "\(projectId.uuidString)/"
        guard remotePath.hasPrefix(expectedPrefix) else {
            try? database.markFileTransferError(
                id: transfer.id,
                error: "Download remote_path project mismatch"
            )
            return .continueDrain
        }

        let localURL = userRootURL.appendingPathComponent(transfer.localRelativePath)

        do {
            if Task.isCancelled { return .stopDrain }
            try database.markFileTransferUploading(id: transfer.id)
            try await remote.downloadPDF(remotePath: remotePath, to: localURL)
            if Task.isCancelled { return .stopDrain }

            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw DrawingPDFRemoteError.downloadFailed("Local file missing after download")
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
                .int64Value
            try database.markFileTransferCompleted(id: transfer.id, bytesDone: bytes)
            downloadLog.info(
                "PDF download completed transfer=\(transfer.id.uuidString, privacy: .public) path=\(remotePath, privacy: .public)"
            )
            return .completed
        } catch {
            try? database.markFileTransferError(
                id: transfer.id,
                error: error.localizedDescription
            )
            downloadLog.error(
                "PDF download failed transfer=\(transfer.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .stopDrain
        }
    }
}
