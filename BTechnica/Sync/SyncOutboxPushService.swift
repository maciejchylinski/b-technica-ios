import Foundation
import Network
import os.log

private let syncLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "SyncOutbox"
)

/// Pushes pending local outbox operations to Supabase.
/// Drawing-folder create / rename / delete, in FIFO order.
@MainActor
final class SyncOutboxPushService {
    static let shared = SyncOutboxPushService()

    private var inFlight: Task<Void, Never>?
    private var rescheduleRequested = false
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.btechnica.sync.path")
    private var lastUserId: UUID?
    private var lastProjectId: UUID?
    private var pathSatisfied = true

    private init() {
        startPathMonitor()
    }

    /// Remembers the active workspace and drains when a connection is available.
    func schedule(userId: UUID, projectId: UUID) {
        lastUserId = userId
        lastProjectId = projectId
        guard pathSatisfied else {
            syncLog.info("Outbox push deferred — network unavailable")
            return
        }
        enqueuePush(userId: userId, projectId: projectId)
    }

    /// Drains folder create/rename/delete ops for the active project.
    func pushPending(
        userId: UUID,
        projectId: UUID,
        remote: DrawingFolderRemoteStore = SupabaseDrawingFolderRemoteStore()
    ) async {
        lastUserId = userId
        lastProjectId = projectId
        guard SupabaseManager.isConfigured else { return }
        guard pathSatisfied else { return }

        do {
            let db = try AppDatabase.shared(for: userId)
            try db.clearOutboxBackoff()
            let entries = try db.fetchOutboxEntries()
            for entry in entries {
                switch try await process(
                    entry: entry,
                    activeProjectId: projectId,
                    database: db,
                    remote: remote
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
        remote: DrawingFolderRemoteStore
    ) async throws -> Step {
        guard entry.entityType == .drawingFolder else {
            // Unknown entity — leave pending; do not skip ahead of it.
            return .stopDrain
        }

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

    private func enqueuePush(userId: UUID, projectId: UUID) {
        if inFlight != nil {
            rescheduleRequested = true
            return
        }
        inFlight = Task { [weak self] in
            // Brief yield so rapid local mutations coalesce into one drain.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self?.pushPending(userId: userId, projectId: projectId)
            guard let self else { return }
            self.inFlight = nil
            if self.rescheduleRequested,
               let userId = self.lastUserId,
               let projectId = self.lastProjectId {
                self.rescheduleRequested = false
                self.enqueuePush(userId: userId, projectId: projectId)
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let becameAvailable = satisfied && !self.pathSatisfied
                self.pathSatisfied = satisfied
                if becameAvailable,
                   let userId = self.lastUserId,
                   let projectId = self.lastProjectId {
                    self.enqueuePush(userId: userId, projectId: projectId)
                }
            }
        }
        monitor.start(queue: pathQueue)
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
            return "Invalid drawing folder outbox payload"
        }
    }
}
