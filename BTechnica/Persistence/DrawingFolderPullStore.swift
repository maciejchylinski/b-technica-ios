import Foundation
import GRDB

/// Summary of a transactional remote → local drawing-folder pull apply.
struct DrawingFolderPullApplyResult: Equatable {
    var upserted: Int
    var removed: Int
    var skippedPending: Int
    /// Tombstones skipped because the folder still has local children or drawings.
    var skippedProtected: Int
}

extension AppDatabase {
    /// Applies remote drawing-folder rows for one project into SQLite.
    ///
    /// - Upserts active remote folders (same UUID / hierarchy).
    /// - Hard-deletes local rows for remote tombstones only when the folder is empty of
    ///   local subfolders and drawings (never cascades into drawings/issues/areas).
    /// - Skips any folder id with a pending local outbox operation.
    /// - Never deletes local-only folders merely absent from `remoteFolders`.
    /// - Does not enqueue outbox rows.
    func applyRemoteDrawingFolderPull(
        projectId: UUID,
        remoteFolders: [RemoteDrawingFolder]
    ) throws -> DrawingFolderPullApplyResult {
        try dbQueue.write { db in
            let pendingIds = try Self.pendingDrawingFolderEntityIds(db: db)
            var upserted = 0
            var removed = 0
            var skippedPending = 0
            var skippedProtected = 0

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
                    if try Self.folderHasLocalDependents(
                        folderId: remote.id,
                        projectId: projectId,
                        db: db
                    ) {
                        skippedProtected += 1
                        continue
                    }
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
                skippedPending: skippedPending,
                skippedProtected: skippedProtected
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

    /// True when local subfolders or drawings still reference this folder.
    private static func folderHasLocalDependents(
        folderId: UUID,
        projectId: UUID,
        db: Database
    ) throws -> Bool {
        let childFolders = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM drawing_folders
            WHERE project_id = ? AND parent_folder_id = ?
            """,
            arguments: [projectId.uuidString, folderId.uuidString]
        ) ?? 0
        if childFolders > 0 { return true }

        let drawings = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM drawings
            WHERE project_id = ? AND folder_id = ?
            """,
            arguments: [projectId.uuidString, folderId.uuidString]
        ) ?? 0
        return drawings > 0
    }
}
