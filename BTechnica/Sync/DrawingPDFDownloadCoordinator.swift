import Foundation
import Network
import os.log

private let downloadCoordinatorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "DrawingPDFDownloadCoordinator"
)

/// On-demand + coalesced retry of drawing PDF downloads for the active project.
/// Invalidated on project switch / logout.
@MainActor
final class DrawingPDFDownloadCoordinator {
    static let shared = DrawingPDFDownloadCoordinator()

    private var generation = 0
    private var inFlight: Task<Void, Never>?
    private var inFlightDrawingId: UUID?
    private var rescheduleRequested = false
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.btechnica.pdfdownload.path")
    private var lastUserId: UUID?
    private var lastProjectId: UUID?
    private var pathSatisfied = true

    /// When true, skip network/config gates (injected fakes in checks).
    var isTestBypassConfigured = false

    private init() {
        startPathMonitor()
    }

    /// Schedules a retry drain of pending/error downloads for the active workspace.
    func schedule(userId: UUID, projectId: UUID) {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId
        guard pathSatisfied || isTestBypassConfigured else {
            downloadCoordinatorLog.info("PDF download deferred — network unavailable")
            return
        }
        enqueue(userId: userId, projectId: projectId)
    }

    func cancel() {
        invalidateStale(reason: "cancelled")
        lastUserId = nil
        lastProjectId = nil
        rescheduleRequested = false
        inFlightDrawingId = nil
    }

    /// Downloads one drawing immediately (UI "Download PDF"). Respects cancellation.
    @discardableResult
    func downloadNow(
        drawingId: UUID,
        userId: UUID,
        projectId: UUID,
        remote: DrawingPDFRemoteStore = SupabaseDrawingPDFRemoteStore(),
        service: DrawingPDFDownloadService = .shared,
        database: AppDatabase? = nil,
        userRootURL: URL? = nil
    ) async -> Bool {
        if lastUserId != userId || lastProjectId != projectId {
            invalidateStale(reason: "workspace changed")
        }
        lastUserId = userId
        lastProjectId = projectId

        let token = generation
        guard SupabaseManager.isConfigured || isTestBypassConfigured else { return false }
        guard pathSatisfied || isTestBypassConfigured else { return false }

        inFlightDrawingId = drawingId
        let ok = await service.download(
            drawingId: drawingId,
            userId: userId,
            projectId: projectId,
            remote: remote,
            database: database,
            userRootURL: userRootURL
        )
        guard !Task.isCancelled, token == generation,
              lastUserId == userId, lastProjectId == projectId
        else {
            downloadCoordinatorLog.info("PDF download aborted (stale/cancelled)")
            return false
        }
        if inFlightDrawingId == drawingId {
            inFlightDrawingId = nil
        }
        return ok
    }

    // MARK: - Internals

    private func invalidateStale(reason: String) {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        inFlightDrawingId = nil
        downloadCoordinatorLog.info("PDF download invalidated — \(reason, privacy: .public)")
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
            await DrawingPDFDownloadService.shared.pullPending(
                userId: userId,
                projectId: projectId
            )
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
