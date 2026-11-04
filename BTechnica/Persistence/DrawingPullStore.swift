import Foundation
import GRDB

/// Summary of a transactional remote → local drawing metadata pull apply.
struct DrawingPullApplyResult: Equatable {
    var upserted: Int
    var removed: Int
    var skippedPending: Int
    /// Tombstones skipped because local issues/areas still reference the drawing.
    var skippedProtected: Int
    /// Active remote rows skipped because they have no current revision yet.
    var skippedIncomplete: Int
}

extension AppDatabase {
    /// Applies remote drawing metadata for one project into SQLite.
    ///
    /// - Upserts active remote drawings (same UUID / folder link) from the current revision.
    /// - Stores remote PDF paths as pending `file_transfers` download rows (no PDF download).
    /// - Hard-deletes local rows for remote tombstones only when no issues/areas reference them.
    /// - Skips any drawing id with a pending local outbox operation.
    /// - Never deletes local-only drawings merely absent from `remoteDrawings`.
    /// - Preserves existing page calibrations and issue/area FK references on upsert.
    /// - Does not enqueue outbox rows or mark PDFs as locally available.
    func applyRemoteDrawingPull(
        projectId: UUID,
        remoteDrawings: [RemoteDrawing]
    ) throws -> DrawingPullApplyResult {
        try dbQueue.write { db in
            let pendingIds = try Self.pendingDrawingEntityIds(db: db)
            var upserted = 0
            var removed = 0
            var skippedPending = 0
            var skippedProtected = 0
            var skippedIncomplete = 0

            for remote in remoteDrawings {
                guard remote.projectId == projectId else { continue }
                if pendingIds.contains(remote.id) {
                    skippedPending += 1
                    continue
                }

                if remote.isTombstone {
                    if try Self.drawingHasLocalDependents(drawingId: remote.id, db: db) {
                        skippedProtected += 1
                        continue
                    }
                    try Self.deleteDrawingPageMappings(drawingId: remote.id, db: db)
                    try db.execute(
                        sql: """
                        DELETE FROM drawings
                        WHERE id = ? AND project_id = ?
                        """,
                        arguments: [remote.id.uuidString, projectId.uuidString]
                    )
                    if db.changesCount > 0 {
                        removed += 1
                    }
                    try Self.deleteDrawingDownloadTransfers(drawingId: remote.id, db: db)
                } else {
                    guard let revision = remote.currentRevision else {
                        skippedIncomplete += 1
                        continue
                    }
                    let drawing = Self.localDrawing(from: remote, revision: revision)
                    try Self.upsertDrawingMetadataPreservingCalibrations(drawing, db: db)
                    try Self.replaceDrawingPageMappings(
                        projectId: projectId,
                        drawingId: remote.id,
                        revisionId: revision.id,
                        pages: revision.pages,
                        now: Date(),
                        db: db
                    )
                    try Self.upsertPendingDrawingPDFDownload(
                        drawingId: remote.id,
                        projectId: projectId,
                        fileName: drawing.fileName,
                        remotePath: revision.storagePath,
                        db: db
                    )
                    try Self.upsertSyncState(
                        key: Self.drawingMetadataSyncKey(remote.id),
                        value: revision.id.uuidString,
                        now: Date(),
                        db: db
                    )
                    upserted += 1
                }
            }

            return DrawingPullApplyResult(
                upserted: upserted,
                removed: removed,
                skippedPending: skippedPending,
                skippedProtected: skippedProtected,
                skippedIncomplete: skippedIncomplete
            )
        }
    }

    /// Drawing entity ids that still have any local outbox row (pending or error).
    func pendingDrawingEntityIds() throws -> Set<UUID> {
        try dbQueue.read { db in
            try Self.pendingDrawingEntityIds(db: db)
        }
    }

    // MARK: - Internals

    private static func pendingDrawingEntityIds(db: Database) throws -> Set<UUID> {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT DISTINCT entity_id
            FROM sync_outbox
            WHERE entity_type = ?
            """,
            arguments: [SyncOutboxEntityType.drawing.rawValue]
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

    private static func drawingHasLocalDependents(drawingId: UUID, db: Database) throws -> Bool {
        let issueCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM issues WHERE drawing_id = ?",
            arguments: [drawingId.uuidString]
        ) ?? 0
        if issueCount > 0 { return true }

        let areaCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM areas WHERE drawing_id = ?",
            arguments: [drawingId.uuidString]
        ) ?? 0
        return areaCount > 0
    }

    private static func localDrawing(
        from remote: RemoteDrawing,
        revision: RemoteDrawingRevision
    ) -> Drawing {
        let fileName: String
        if let original = Drawing.nonEmpty(revision.originalFileName) {
            fileName = original
        } else {
            fileName = "\(remote.id.uuidString).pdf"
        }
        let pageCount = max(revision.pageCount, revision.pages.count)
        return Drawing(
            id: remote.id,
            projectId: remote.projectId,
            folderId: remote.folderId,
            name: remote.name,
            fileName: fileName,
            pageCount: pageCount,
            createdDate: remote.createdAt,
            revision: revision.revisionLabel,
            discipline: remote.discipline,
            location: remote.location,
            drawingDate: revision.drawingDate,
            calibrations: []
        )
    }

    /// Upserts drawing row fields without touching `page_calibrations`.
    private static func upsertDrawingMetadataPreservingCalibrations(
        _ drawing: Drawing,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO drawings
              (id, project_id, folder_id, name, file_name, page_count, created_at,
               revision, discipline, location, drawing_date)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              project_id = excluded.project_id,
              folder_id = excluded.folder_id,
              name = excluded.name,
              file_name = excluded.file_name,
              page_count = excluded.page_count,
              created_at = excluded.created_at,
              revision = excluded.revision,
              discipline = excluded.discipline,
              location = excluded.location,
              drawing_date = excluded.drawing_date
            """,
            arguments: [
                drawing.id.uuidString,
                drawing.projectId.uuidString,
                drawing.folderId?.uuidString,
                drawing.name,
                drawing.fileName,
                drawing.pageCount,
                SQLiteDateCoding.string(from: drawing.createdDate),
                drawing.revision,
                drawing.discipline,
                drawing.location,
                drawing.drawingDate.map(SQLiteDateCoding.string(from:))
            ]
        )
    }
}
