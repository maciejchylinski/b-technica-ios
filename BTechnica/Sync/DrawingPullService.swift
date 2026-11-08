import Foundation
import os.log

private let drawingPullLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "DrawingPull"
)

/// Pulls drawing metadata (drawings / current revisions / pages) from Supabase into SQLite.
/// Scheduling is owned by `DrawingFolderSyncCoordinator` (after folder pull).
@MainActor
final class DrawingPullService {
    static let shared = DrawingPullService()

    private var refreshHandler: (@MainActor () -> Void)?

    private init() {}

    /// Fetches remote drawings for `projectId` and applies them into SQLite.
    /// Pass `database` to use an isolated DB (coordinator checks); otherwise the shared user DB.
    @discardableResult
    func pull(
        userId: UUID,
        projectId: UUID,
        remote: DrawingRemoteStore = SupabaseDrawingRemoteStore(),
        onApplied: (@MainActor () -> Void)? = nil,
        database: AppDatabase? = nil
    ) async -> DrawingPullApplyResult? {
        if let onApplied {
            refreshHandler = onApplied
        }
        guard !LocalOnlyWorkspace.isLocalOnly(userId: userId), SupabaseManager.isConfigured || DrawingFolderSyncCoordinator.shared.isTestBypassConfigured else {
            return nil
        }

        do {
            let remoteDrawings = try await remote.fetchProjectDrawings(projectId: projectId)
            if Task.isCancelled { return nil }
            let db = try database ?? AppDatabase.shared(for: userId)
            let result = try db.applyRemoteDrawingPull(
                projectId: projectId,
                remoteDrawings: remoteDrawings
            )
            refreshHandler?()
            drawingPullLog.info(
                "Drawing pull applied upserted=\(result.upserted) removed=\(result.removed) skippedPending=\(result.skippedPending) skippedProtected=\(result.skippedProtected) skippedIncomplete=\(result.skippedIncomplete)"
            )
            return result
        } catch {
            drawingPullLog.error("Drawing pull failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
