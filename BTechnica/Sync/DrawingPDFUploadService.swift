import Foundation
import os.log

private let uploadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "DrawingPDFUpload"
)

/// Drains pending/error drawing PDF uploads for the active project into private Storage.
/// Scheduling / networking are owned by `DrawingPDFUploadCoordinator`.
@MainActor
final class DrawingPDFUploadService {
    static let shared = DrawingPDFUploadService()

    private init() {}

    func schedule(userId: UUID, projectId: UUID) {
        DrawingPDFUploadCoordinator.shared.schedule(userId: userId, projectId: projectId)
    }

    /// Uploads incomplete drawing PDF transfers for `projectId`. Local files are never deleted.
    func pushPending(
        userId: UUID,
        projectId: UUID,
        remote: DrawingPDFRemoteStore = SupabaseDrawingPDFRemoteStore(),
        database: AppDatabase? = nil,
        userRootURL: URL? = nil
    ) async {
        guard !LocalOnlyWorkspace.isLocalOnly(userId: userId), SupabaseManager.isConfigured || DrawingPDFUploadCoordinator.shared.isTestBypassConfigured else {
            return
        }

        do {
            let db = try database ?? AppDatabase.shared(for: userId)
            let root = userRootURL ?? db.rootURL
            let transfers = try db.fetchPendingDrawingPDFUploads(projectId: projectId)
            for transfer in transfers {
                if Task.isCancelled { return }
                let outcome = await process(
                    transfer: transfer,
                    userId: userId,
                    projectId: projectId,
                    database: db,
                    remote: remote,
                    userRootURL: root
                )
                if outcome == .stopDrain { return }
            }
        } catch {
            uploadLog.error("PDF upload drain failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Processing

    private enum Step {
        case continueDrain
        case stopDrain
    }

    private func process(
        transfer: FileTransfer,
        userId: UUID,
        projectId: UUID,
        database: AppDatabase,
        remote: DrawingPDFRemoteStore,
        userRootURL: URL
    ) async -> Step {
        guard transfer.direction == .upload,
              transfer.entityType == .drawing,
              let remotePath = transfer.remotePath,
              !remotePath.isEmpty
        else {
            try? database.markFileTransferError(
                id: transfer.id,
                error: "Invalid drawing PDF transfer row"
            )
            return .stopDrain
        }

        let localURL = userRootURL.appendingPathComponent(transfer.localRelativePath)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            try? database.markFileTransferError(
                id: transfer.id,
                error: DrawingPDFRemoteError.invalidLocalFile.localizedDescription
            )
            return .continueDrain
        }

        do {
            try database.markFileTransferUploading(id: transfer.id)
            try await remote.uploadPDF(localURL: localURL, remotePath: remotePath)
            // Confirm before marking complete — upload helpers also check exists.
            guard try await remote.objectExists(remotePath: remotePath) else {
                throw DrawingPDFRemoteError.uploadFailed("Object missing after upload")
            }
            let bytes = transfer.bytesTotal
                ?? (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64)
            try database.markFileTransferCompleted(id: transfer.id, bytesDone: bytes)
            // Metadata outbox only after confirmed Storage upload (never for legacy-only locals).
            _ = try? database.enqueueDrawingMetadataSyncIfNeeded(drawingId: transfer.entityId)
            SyncOutboxPushService.shared.schedule(userId: userId, projectId: projectId)
            uploadLog.info(
                "PDF upload completed transfer=\(transfer.id.uuidString, privacy: .public) path=\(remotePath, privacy: .public)"
            )
            return .continueDrain
        } catch {
            try? database.markFileTransferError(
                id: transfer.id,
                error: error.localizedDescription
            )
            uploadLog.error(
                "PDF upload failed transfer=\(transfer.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Network / auth failures: stop so reconnect can retry in order.
            return .stopDrain
        }
    }
}
