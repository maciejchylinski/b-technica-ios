import Foundation
import Network
import os.log

private let coordinatorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "DrawingPDFUploadCoordinator"
)

/// Coalesced drain of pending drawing PDF uploads for the active project.
/// Retries after reconnect; invalidated on project switch / logout.
@MainActor
final class DrawingPDFUploadCoordinator {
    static let shared = DrawingPDFUploadCoordinator()

    private var generation = 0
    private var inFlight: Task<Void, Never>?
    private var rescheduleRequested = false
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.btechnica.pdfupload.path")
    private var lastUserId: UUID?
    private var lastProjectId: UUID?
    private var pathSatisfied = true

    /// When true, skip network/config gates (injected fakes in checks).
    var isTestBypassConfigured = false

    private init() {
        startPathMonitor()
    }

    func schedule(userId: UUID, projectId: UUID) {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId
        guard pathSatisfied || isTestBypassConfigured else {
            coordinatorLog.info("PDF upload deferred — network unavailable")
            return
        }
        enqueue(userId: userId, projectId: projectId)
    }

    func cancel() {
        invalidateStale(reason: "cancelled")
        lastUserId = nil
        lastProjectId = nil
        rescheduleRequested = false
    }

    @discardableResult
    func uploadNow(
        userId: UUID,
        projectId: UUID,
        remote: DrawingPDFRemoteStore = SupabaseDrawingPDFRemoteStore(),
        service: DrawingPDFUploadService = .shared,
        database: AppDatabase? = nil,
        userRootURL: URL? = nil
    ) async -> Bool {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId

        let token = generation
        guard !LocalOnlyWorkspace.isLocalOnly(userId: userId), SupabaseManager.isConfigured || isTestBypassConfigured else { return false }
        guard pathSatisfied || isTestBypassConfigured else { return false }

        await service.pushPending(
            userId: userId,
            projectId: projectId,
            remote: remote,
            database: database,
            userRootURL: userRootURL
        )
        guard !Task.isCancelled, token == generation,
              lastUserId == userId, lastProjectId == projectId
        else {
            coordinatorLog.info("PDF upload aborted (stale/cancelled)")
            return false
        }
        return true
    }

    // MARK: - Internals

    private func invalidateStale(reason: String) {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        coordinatorLog.info("PDF upload invalidated — \(reason, privacy: .public)")
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
            _ = await self.uploadNow(userId: userId, projectId: projectId)
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
