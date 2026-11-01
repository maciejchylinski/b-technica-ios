import Foundation
import os.log

private let syncLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "SyncOutbox"
)

/// Pushes pending local outbox operations to Supabase.
/// Drawing-folder create / rename / delete, then drawing metadata create, in FIFO order.
/// Scheduling / networking are owned by `DrawingFolderSyncCoordinator`.
@MainActor
final class SyncOutboxPushService {
    static let shared = SyncOutboxPushService()

    private init() {}

    /// Forwards to the shared folder sync coordinator (push then pull).
    func schedule(userId: UUID, projectId: UUID) {
        DrawingFolderSyncCoordinator.shared.schedule(userId: userId, projectId: projectId)
    }

    /// Drains folder + drawing metadata ops for the active project.
    /// Pass `database` to use an isolated DB (coordinator checks); otherwise the shared user DB.
    func pushPending(
        userId: UUID,
        projectId: UUID,
        remote: DrawingFolderRemoteStore = SupabaseDrawingFolderRemoteStore(),
        drawingRemote: DrawingRemoteStore = SupabaseDrawingRemoteStore(),
        database: AppDatabase? = nil
    ) async {
        guard SupabaseManager.isConfigured || DrawingFolderSyncCoordinator.shared.isTestBypassConfigured else {
            return
        }

        do {
            let db = try database ?? AppDatabase.shared(for: userId)
            try db.clearOutboxBackoff()
            let entries = try db.fetchOutboxEntries()
            for entry in entries {
                if Task.isCancelled { return }
                switch try await process(
                    entry: entry,
                    activeProjectId: projectId,
                    database: db,
                    folderRemote: remote,
                    drawingRemote: drawingRemote
                ) {
                case .continueDrain:
                    continue
                case .stopDrain:
                    return
                }
            }
        } catch {
            syncLog.error("Outbox push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Processing

    private enum Step {
        case continueDrain
        case stopDrain
    }

    private func process(
        entry: SyncOutboxEntry,
        activeProjectId: UUID,
        database: AppDatabase,
        folderRemote: DrawingFolderRemoteStore,
        drawingRemote: DrawingRemoteStore
    ) async throws -> Step {
        switch entry.entityType {
        case .drawingFolder:
            return try await processFolder(
                entry: entry,
                activeProjectId: activeProjectId,
                database: database,
                remote: folderRemote
            )
        case .drawing:
            return try await processDrawing(
                entry: entry,
                activeProjectId: activeProjectId,
                database: database,
                folderRemote: folderRemote,
                drawingRemote: drawingRemote
            )
        }
    }

    private func processFolder(
        entry: SyncOutboxEntry,
        activeProjectId: UUID,
        database: AppDatabase,
        remote: DrawingFolderRemoteStore
    ) async throws -> Step {
        let folder: DrawingFolder
        do {
            folder = try Self.folder(from: entry)
        } catch {
            try database.markOutboxError(
                operationId: entry.id,
                error: error.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        }

        guard folder.projectId == activeProjectId else {
            // Keep global FIFO: wait until that project is active.
            return .stopDrain
        }

        do {
            switch entry.operation {
            case .create:
                _ = try await remote.ensureCreated(folder)
            case .update:
                _ = try await remote.ensureRenamed(folder)
            case .delete:
                _ = try await remote.ensureDeleted(folder)
            }
            try database.markOutboxSent(operationId: entry.id)
            syncLog.info(
                "Outbox \(entry.operation.rawValue, privacy: .public) sent op=\(entry.id.uuidString, privacy: .public) folder=\(folder.id.uuidString, privacy: .public)"
            )
            return .continueDrain
        } catch let remoteError as DrawingFolderRemoteError {
            try database.markOutboxError(
                operationId: entry.id,
                error: remoteError.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        } catch {
            try database.markOutboxError(
                operationId: entry.id,
                error: error.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            syncLog.error(
                "Outbox \(entry.operation.rawValue, privacy: .public) failed op=\(entry.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .stopDrain
        }
    }

    private func processDrawing(
        entry: SyncOutboxEntry,
        activeProjectId: UUID,
        database: AppDatabase,
        folderRemote: DrawingFolderRemoteStore,
        drawingRemote: DrawingRemoteStore
    ) async throws -> Step {
        let payload: DrawingMetadataPayload
        do {
            payload = try Self.drawingPayload(from: entry)
        } catch {
            try database.markOutboxError(
                operationId: entry.id,
                error: error.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        }

        guard payload.projectId == activeProjectId else {
            return .stopDrain
        }

        guard entry.operation == .create else {
            try database.markOutboxError(
                operationId: entry.id,
                error: "Unsupported drawing outbox operation \(entry.operation.rawValue)",
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        }

        // Metadata only after confirmed PDF upload; keep transfer + outbox consistent.
        guard let transfer = try database.fetchDrawingPDFUpload(drawingId: payload.id),
              transfer.status == .completed,
              transfer.remotePath == payload.storagePath
        else {
            try database.markOutboxError(
                operationId: entry.id,
                error: DrawingRemoteError.pdfNotUploaded(
                    "PDF upload not confirmed for drawing \(payload.id)"
                ).localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        }

        do {
            if let folderId = payload.folderId {
                guard let folder = try database.fetchDrawingFolder(id: folderId) else {
                    throw DrawingRemoteError.conflict(
                        "Local parent folder \(folderId) missing for drawing \(payload.id)"
                    )
                }
                guard folder.projectId == payload.projectId else {
                    throw DrawingRemoteError.conflict(
                        "Parent folder project mismatch for drawing \(payload.id)"
                    )
                }
                _ = try await folderRemote.ensureCreated(folder)
            }

            _ = try await drawingRemote.ensureCreated(payload)
            try database.markDrawingMetadataPushed(
                drawingId: payload.id,
                revisionId: payload.revisionId
            )
            try database.markOutboxSent(operationId: entry.id)
            syncLog.info(
                "Outbox drawing create sent op=\(entry.id.uuidString, privacy: .public) drawing=\(payload.id.uuidString, privacy: .public)"
            )
            return .continueDrain
        } catch let remoteError as DrawingRemoteError {
            try database.markOutboxError(
                operationId: entry.id,
                error: remoteError.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        } catch let remoteError as DrawingFolderRemoteError {
            try database.markOutboxError(
                operationId: entry.id,
                error: remoteError.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            return .stopDrain
        } catch {
            try database.markOutboxError(
                operationId: entry.id,
                error: error.localizedDescription,
                nextAttemptAt: Self.nextAttemptDate(attemptCount: entry.attemptCount)
            )
            syncLog.error(
                "Outbox drawing create failed op=\(entry.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .stopDrain
        }
    }

    nonisolated static func folder(from entry: SyncOutboxEntry) throws -> DrawingFolder {
        guard let raw = entry.payloadJSON,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idRaw = object["id"] as? String,
              let id = UUID(uuidString: idRaw),
              let projectRaw = object["projectId"] as? String,
              let projectId = UUID(uuidString: projectRaw),
              let name = object["name"] as? String
        else {
            throw SyncOutboxPushError.invalidPayload
        }
        let parent: UUID?
        if object["parentFolderId"] is NSNull || object["parentFolderId"] == nil {
            parent = nil
        } else if let parentRaw = object["parentFolderId"] as? String {
            parent = UUID(uuidString: parentRaw)
        } else {
            throw SyncOutboxPushError.invalidPayload
        }
        let sortOrder = (object["sortOrder"] as? Int)
            ?? (object["sortOrder"] as? NSNumber)?.intValue
            ?? 0
        let createdDate: Date
        if let createdRaw = object["createdDate"] as? String,
           let parsed = SQLiteDateCoding.date(from: createdRaw) {
            createdDate = parsed
        } else {
            createdDate = entry.createdAt
        }
        return DrawingFolder(
            id: id,
            projectId: projectId,
            parentFolderId: parent,
            name: name,
            sortOrder: sortOrder,
            createdDate: createdDate
        )
    }

    nonisolated static func drawingPayload(from entry: SyncOutboxEntry) throws -> DrawingMetadataPayload {
        guard let raw = entry.payloadJSON,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idRaw = object["id"] as? String,
              let id = UUID(uuidString: idRaw),
              let projectRaw = object["projectId"] as? String,
              let projectId = UUID(uuidString: projectRaw),
              let name = object["name"] as? String,
              let fileName = object["fileName"] as? String,
              let storagePath = object["storagePath"] as? String,
              let revisionRaw = object["revisionId"] as? String,
              let revisionId = UUID(uuidString: revisionRaw)
        else {
            throw SyncOutboxPushError.invalidPayload
        }

        let pageCount = (object["pageCount"] as? Int)
            ?? (object["pageCount"] as? NSNumber)?.intValue
            ?? 0

        let folderId: UUID?
        if object["folderId"] is NSNull || object["folderId"] == nil {
            folderId = nil
        } else if let folderRaw = object["folderId"] as? String {
            folderId = UUID(uuidString: folderRaw)
        } else {
            throw SyncOutboxPushError.invalidPayload
        }

        let createdDate: Date
        if let createdRaw = object["createdDate"] as? String,
           let parsed = SQLiteDateCoding.date(from: createdRaw) {
            createdDate = parsed
        } else {
            createdDate = entry.createdAt
        }

        let drawingDate: Date?
        if object["drawingDate"] is NSNull || object["drawingDate"] == nil {
            drawingDate = nil
        } else if let drawingRaw = object["drawingDate"] as? String {
            drawingDate = SQLiteDateCoding.date(from: drawingRaw)
        } else {
            drawingDate = nil
        }

        return DrawingMetadataPayload(
            id: id,
            projectId: projectId,
            folderId: folderId,
            name: name,
            fileName: fileName,
            pageCount: pageCount,
            createdDate: createdDate,
            revisionLabel: object["revision"] as? String,
            discipline: object["discipline"] as? String,
            location: object["location"] as? String,
            drawingDate: drawingDate,
            revisionId: revisionId,
            storagePath: storagePath
        )
    }

    nonisolated static func nextAttemptDate(attemptCount: Int, now: Date = Date()) -> Date {
        let capped = min(attemptCount + 1, 6)
        let delay = pow(2.0, Double(capped)) // 2…64 seconds
        return now.addingTimeInterval(delay)
    }
}

enum SyncOutboxPushError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid sync outbox payload"
        }
    }
}
