import Foundation
import Network
import os.log

private let pullLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "FolderPull"
)

/// Pulls drawing folders from Supabase into local SQLite for the active project.
@MainActor
final class DrawingFolderPullService {
    static let shared = DrawingFolderPullService()

    private var inFlight: Task<Void, Never>?
    private var rescheduleRequested = false
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.btechnica.folderpull.path")
    private var lastUserId: UUID?
    private var lastProjectId: UUID?
    private var pathSatisfied = true
    private var refreshHandler: (@MainActor () -> Void)?

    private init() {
        startPathMonitor()
    }

    /// Remembers the active workspace and pulls when a connection is available.
    /// `onApplied` refreshes in-memory UI after a successful SQLite apply (e.g. AppStore).
    func schedule(
        userId: UUID,
        projectId: UUID,
        onApplied: (@MainActor () -> Void)? = nil
    ) {
        lastUserId = userId
        lastProjectId = projectId
        if let onApplied {
            refreshHandler = onApplied
        }
        guard pathSatisfied else {
            pullLog.info("Folder pull deferred — network unavailable")
            return
        }
        enqueuePull(userId: userId, projectId: projectId)
    }

    /// Fetches remote folders for `projectId` and applies them into SQLite.
    @discardableResult
    func pull(
        userId: UUID,
        projectId: UUID,
        remote: DrawingFolderRemoteStore = SupabaseDrawingFolderRemoteStore(),
        onApplied: (@MainActor () -> Void)? = nil
    ) async -> DrawingFolderPullApplyResult? {
        lastUserId = userId
        lastProjectId = projectId
        if let onApplied {
            refreshHandler = onApplied
        }
        guard SupabaseManager.isConfigured else { return nil }
        guard pathSatisfied else { return nil }

        do {
            let remoteFolders = try await remote.fetchProjectFolders(projectId: projectId)
            let db = try AppDatabase.shared(for: userId)
            let result = try db.applyRemoteDrawingFolderPull(
                projectId: projectId,
                remoteFolders: remoteFolders
            )
            refreshHandler?()
            pullLog.info(
                "Folder pull applied upserted=\(result.upserted) removed=\(result.removed) skipped=\(result.skippedPending)"
            )
            return result
        } catch {
            pullLog.error("Folder pull failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func enqueuePull(userId: UUID, projectId: UUID) {
        if inFlight != nil {
            rescheduleRequested = true
            return
        }
        inFlight = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            _ = await self?.pull(userId: userId, projectId: projectId)
            guard let self else { return }
            self.inFlight = nil
            if self.rescheduleRequested,
               let userId = self.lastUserId,
               let projectId = self.lastProjectId {
                self.rescheduleRequested = false
                self.enqueuePull(userId: userId, projectId: projectId)
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
                    self.enqueuePull(userId: userId, projectId: projectId)
                }
            }
        }
        monitor.start(queue: pathQueue)
    }
}
