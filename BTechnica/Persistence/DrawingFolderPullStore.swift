import Foundation
import GRDB

/// Summary of a transactional remote → local drawing-folder pull apply.
struct DrawingFolderPullApplyResult: Equatable {
    var upserted: Int
    var removed: Int
    var skippedPending: Int
}

extension AppDatabase {
    /// Applies remote drawing-folder rows for one project into SQLite.
    ///
    /// - Upserts active remote folders (same UUID / hierarchy).
    /// - Hard-deletes local rows for remote tombstones (`deleted_at` set).
    /// - Skips any folder id with a pending local outbox operation.
    /// - Never deletes local-only folders merely absent from `remoteFolders`.
    /// - Does not enqueue outbox rows.
    /// - Does not touch drawings / issues / areas (no FK cascade from folders).
    func applyRemoteDrawingFolderPull(
        projectId: UUID,
        remoteFolders: [RemoteDrawingFolder]
    ) throws -> DrawingFolderPullApplyResult {
        try dbQueue.write { db in
            let pendingIds = try Self.pendingDrawingFolderEntityIds(db: db)
            var upserted = 0
            var removed = 0
            var skippedPending = 0

            // Parents before children keeps hierarchy readable; local schema has no parent FK.
            let ordered = remoteFolders.sorted { lhs, rhs in
                switch (lhs.parentFolderId, rhs.parentFolderId) {
                case (nil, .some):
                    return true
                case (.some, nil):
                    return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }

            for remote in ordered {
                guard remote.projectId == projectId else { continue }
                if pendingIds.contains(remote.id) {
                    skippedPending += 1
                    continue
                }

                if remote.isTombstone {
                    try db.execute(
                        sql: """
                        DELETE FROM drawing_folders
                        WHERE id = ? AND project_id = ?
                        """,
                        arguments: [remote.id.uuidString, projectId.uuidString]
                    )
                    if db.changesCount > 0 {
                        removed += 1
                    }
                } else {
                    try Self.upsertFolders([remote.asLocalFolder()], db: db)
                    upserted += 1
                }
            }

            return DrawingFolderPullApplyResult(
                upserted: upserted,
                removed: removed,
                skippedPending: skippedPending
            )
        }
    }

    /// Folder entity ids that still have any local outbox row (pending or error).
    func pendingDrawingFolderEntityIds() throws -> Set<UUID> {
        try dbQueue.read { db in
            try Self.pendingDrawingFolderEntityIds(db: db)
        }
    }

    private static func pendingDrawingFolderEntityIds(db: Database) throws -> Set<UUID> {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT DISTINCT entity_id
            FROM sync_outbox
            WHERE entity_type = ?
            """,
            arguments: [SyncOutboxEntityType.drawingFolder.rawValue]
        )
        var ids = Set<UUID>()
        for row in rows {
            let raw: String = row["entity_id"]
            if let id = UUID(uuidString: raw) {
                ids.insert(id)
            }
        }
        return ids
    }
}
