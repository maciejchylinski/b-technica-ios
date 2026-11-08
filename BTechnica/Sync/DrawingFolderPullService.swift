import Foundation
import os.log

private let pullLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "FolderPull"
)

/// Pulls drawing folders from Supabase into local SQLite for the active project.
/// Scheduling / networking are owned by `DrawingFolderSyncCoordinator`.
@MainActor
final class DrawingFolderPullService {
    static let shared = DrawingFolderPullService()

    private var refreshHandler: (@MainActor () -> Void)?

    private init() {}

    /// Forwards to the shared folder sync coordinator (push then pull).
    func schedule(
        userId: UUID,
        projectId: UUID,
        onApplied: (@MainActor () -> Void)? = nil
    ) {
        DrawingFolderSyncCoordinator.shared.schedule(
            userId: userId,
            projectId: projectId,
            onApplied: onApplied
        )
    }

    /// Fetches remote folders for `projectId` and applies them into SQLite.
    /// Pass `database` to use an isolated DB (coordinator checks); otherwise the shared user DB.
    @discardableResult
    func pull(
        userId: UUID,
        projectId: UUID,
        remote: DrawingFolderRemoteStore = SupabaseDrawingFolderRemoteStore(),
        onApplied: (@MainActor () -> Void)? = nil,
        database: AppDatabase? = nil
    ) async -> DrawingFolderPullApplyResult? {
        if let onApplied {
            refreshHandler = onApplied
        }
        guard !LocalOnlyWorkspace.isLocalOnly(userId: userId), SupabaseManager.isConfigured || DrawingFolderSyncCoordinator.shared.isTestBypassConfigured else {
            return nil
        }

        do {
            let remoteFolders = try await remote.fetchProjectFolders(projectId: projectId)
            if Task.isCancelled { return nil }
            let db = try database ?? AppDatabase.shared(for: userId)
            let result = try db.applyRemoteDrawingFolderPull(
                projectId: projectId,
                remoteFolders: remoteFolders
            )
            refreshHandler?()
            pullLog.info(
                "Folder pull applied upserted=\(result.upserted) removed=\(result.removed) skippedPending=\(result.skippedPending) skippedProtected=\(result.skippedProtected)"
            )
            return result
        } catch {
            pullLog.error("Folder pull failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
