import Foundation
import Network
import os.log

private let coordinatorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "FolderSyncCoordinator"
)

/// Single entry point for drawing-folder sync: push pending outbox, then pull remote.
/// One in-flight run per active project; stale work is invalidated on project switch / logout.
@MainActor
final class DrawingFolderSyncCoordinator {
    static let shared = DrawingFolderSyncCoordinator()

    private var generation = 0
    private var inFlight: Task<Void, Never>?
    private var rescheduleRequested = false
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.btechnica.foldersync.path")
    private var lastUserId: UUID?
    private var lastProjectId: UUID?
    private var pathSatisfied = true
    private var refreshHandler: (@MainActor () -> Void)?

    /// Test/observability: last completed run summary (nil if cancelled/failed early).
    private(set) var lastResult: DrawingFolderSyncResult?

    private init() {
        startPathMonitor()
    }

    /// Schedules a coalesced push→pull for the active workspace.
    func schedule(
        userId: UUID,
        projectId: UUID,
        onApplied: (@MainActor () -> Void)? = nil
    ) {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId
        if let onApplied {
            refreshHandler = onApplied
        }
        guard pathSatisfied else {
            coordinatorLog.info("Folder sync deferred — network unavailable")
            return
        }
        enqueue(userId: userId, projectId: projectId)
    }

    /// Cancels in-flight work and clears workspace binding (logout / leave project).
    func cancel() {
        invalidateStale(reason: "cancelled")
        lastUserId = nil
        lastProjectId = nil
        refreshHandler = nil
        rescheduleRequested = false
    }

    /// Runs push then folder pull then drawing metadata pull once.
    /// Pass `database` for isolated coordinator checks; production omits it (shared user DB).
    @discardableResult
    func syncNow(
        userId: UUID,
        projectId: UUID,
        remote: DrawingFolderRemoteStore = SupabaseDrawingFolderRemoteStore(),
        drawingRemote: DrawingRemoteStore = SupabaseDrawingRemoteStore(),
        push: SyncOutboxPushService = .shared,
        pull: DrawingFolderPullService = .shared,
        drawingPull: DrawingPullService = .shared,
        onApplied: (@MainActor () -> Void)? = nil,
        database: AppDatabase? = nil
    ) async -> DrawingFolderSyncResult? {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId
        if let onApplied {
            refreshHandler = onApplied
        }

        let token = generation
        guard !LocalOnlyWorkspace.isLocalOnly(userId: userId), SupabaseManager.isConfigured || isTestBypassConfigured else {
            return nil
        }
        guard pathSatisfied || isTestBypassConfigured else { return nil }

        // 1) Drain local outbox first so remote pull cannot overwrite unsent work.
        await push.pushPending(
            userId: userId,
            projectId: projectId,
            remote: remote,
            database: database
        )
        guard !Task.isCancelled, token == generation,
              lastUserId == userId, lastProjectId == projectId
        else {
            coordinatorLog.info("Folder sync aborted after push (stale/cancelled)")
            return nil
        }

        // 2) Pull folders first so drawing.folder_id FKs resolve.
        //    Pending outbox rows stay protected inside applyRemoteDrawingFolderPull.
        //    Refresh memory right after applying: if step 3 fails, the workspace must not
        //    keep showing (and saving from) the pre-pull folder list.
        let pullResult = await pull.pull(
            userId: userId,
            projectId: projectId,
            remote: remote,
            onApplied: refreshHandler,
            database: database
        )
        guard !Task.isCancelled, token == generation,
              lastUserId == userId, lastProjectId == projectId
        else {
            coordinatorLog.info("Folder sync aborted after folder pull (stale/cancelled)")
            return nil
        }

        // 3) Pull drawing metadata (no PDF download). Pending drawing outbox rows stay protected.
        let drawingPullResult = await drawingPull.pull(
            userId: userId,
            projectId: projectId,
            remote: drawingRemote,
            onApplied: refreshHandler,
            database: database
        )
        guard !Task.isCancelled, token == generation,
              lastUserId == userId, lastProjectId == projectId
        else {
            coordinatorLog.info("Folder sync aborted after drawing pull (stale/cancelled)")
            return nil
        }

        let result = DrawingFolderSyncResult(
            userId: userId,
            projectId: projectId,
            pull: pullResult,
            drawingPull: drawingPullResult
        )
        lastResult = result
        coordinatorLog.info(
            "Folder sync finished project=\(projectId.uuidString, privacy: .public) folders=\(String(describing: pullResult), privacy: .public) drawings=\(String(describing: drawingPullResult), privacy: .public)"
        )
        return result
    }

    // MARK: - Internals

    /// When true, skip network/config gates (unit/coordinator checks inject fakes).
    var isTestBypassConfigured = false

    private func invalidateStale(reason: String) {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        coordinatorLog.info("Folder sync invalidated — \(reason, privacy: .public)")
    }

    private func enqueue(userId: UUID, projectId: UUID) {
        if inFlight != nil {
            rescheduleRequested = true
            return
        }
        let token = generation
        inFlight = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            _ = await self.syncNow(userId: userId, projectId: projectId)
            self.inFlight = nil
            if self.rescheduleRequested,
               let userId = self.lastUserId,
               let projectId = self.lastProjectId,
               token == self.generation {
                self.rescheduleRequested = false
                self.enqueue(userId: userId, projectId: projectId)
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
                    self.enqueue(userId: userId, projectId: projectId)
                }
            }
        }
        monitor.start(queue: pathQueue)
    }
}

/// Summary of one coordinator sync cycle.
struct DrawingFolderSyncResult: Equatable {
    var userId: UUID
    var projectId: UUID
    var pull: DrawingFolderPullApplyResult?
    var drawingPull: DrawingPullApplyResult?
}
