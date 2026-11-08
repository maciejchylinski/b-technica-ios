import Foundation
import GRDB

/// SQLite read/write for drawing folders, drawings, and page calibrations.
/// Authoritative after JSON → SQLite import; PDF bytes stay on disk under `Drawings/`.
extension AppDatabase {
    /// Ensures the local `projects` row exists (FK parent for folders/drawings).
    func ensureProject(_ project: Project) throws {
        try dbQueue.write { db in
            try Self.upsertProject(project, db: db)
        }
    }

    func fetchDrawingFolders(projectId: UUID) throws -> [DrawingFolder] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, parent_folder_id, name, sort_order, created_at
                FROM drawing_folders
                WHERE project_id = ?
                ORDER BY sort_order ASC, name ASC
                """,
                arguments: [projectId.uuidString]
            )
            return try rows.map { try Self.folder(from: $0) }
        }
    }

    func fetchDrawing(id: UUID) throws -> Drawing? {
        try dbQueue.read { db in
            try Self.fetchDrawingRow(id: id, db: db)
        }
    }

    func fetchDrawingFolder(id: UUID) throws -> DrawingFolder? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, project_id, parent_folder_id, name, sort_order, created_at
                FROM drawing_folders
                WHERE id = ?
                """,
                arguments: [id.uuidString]
            )
            return try row.map { try Self.folder(from: $0) }
        }
    }

    func fetchDrawings(projectId: UUID) throws -> [Drawing] {
        try dbQueue.read { db in
            let drawingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, folder_id, name, file_name, page_count, created_at,
                       revision, discipline, location, drawing_date
                FROM drawings
                WHERE project_id = ?
                ORDER BY created_at ASC, name ASC
                """,
                arguments: [projectId.uuidString]
            )

            // One grouped calibration query instead of one query per drawing.
            let calibrationsByDrawing = try Self.fetchCalibrationsByDrawing(projectId: projectId, db: db)
            var result: [Drawing] = []
            result.reserveCapacity(drawingRows.count)
            for row in drawingRows {
                var drawing = try Self.drawing(from: row)
                drawing.calibrations = calibrationsByDrawing[drawing.id.uuidString] ?? []
                result.append(drawing)
            }
            return result
        }
    }

    /// Upserts folders/drawings/calibrations. Orphan drawing deletion is skipped when
    /// related issues/areas still exist (avoids CASCADE wiping them). Prefer
    /// `persistProjectWorkspace` for full project graphs.
    func replaceFoldersAndDrawings(
        project: Project,
        folders: [DrawingFolder],
        drawings: [Drawing]
    ) throws {
        try dbQueue.write { db in
            try Self.upsertProject(project, db: db)
            try Self.upsertFolders(folders, db: db)
            try Self.upsertDrawingsAndCalibrations(drawings, db: db)
            try Self.deleteOrphanFolders(
                projectId: project.id,
                keepIds: Set(folders.map(\.id.uuidString)),
                db: db
            )
            try Self.deleteOrphanDrawings(
                projectId: project.id,
                keepIds: Set(drawings.map(\.id.uuidString)),
                requireNoDependents: true,
                db: db
            )
        }
    }

    /// Atomically persists folders, drawings, areas, issues, and photo metadata.
    /// Editing drawing metadata never cascades away related issues/areas/photos.
    /// Explicit removals from the in-memory keep-sets are deleted in dependency order.
    func persistProjectWorkspace(
        project: Project,
        folders: [DrawingFolder],
        drawings: [Drawing],
        areas: [Area],
        issues: [Issue]
    ) throws {
        try dbQueue.write { db in
            try Self.upsertProject(project, db: db)
            try Self.upsertFolders(folders, db: db)
            try Self.upsertDrawingsAndCalibrations(drawings, db: db)
            try Self.upsertAreas(areas, db: db)
            try Self.upsertIssuesAndPhotos(issues, projectId: project.id, db: db)

            // Controlled deletions — dependents before parents (no surprise CASCADE loss).
            try Self.deleteOrphanIssues(
                projectId: project.id,
                keepIds: Set(issues.map(\.id.uuidString)),
                db: db
            )
            try Self.deleteOrphanAreas(
                projectId: project.id,
                keepIds: Set(areas.map(\.id.uuidString)),
                db: db
            )
            try Self.deleteOrphanDrawings(
                projectId: project.id,
                keepIds: Set(drawings.map(\.id.uuidString)),
                requireNoDependents: false,
                db: db
            )
            try Self.deleteOrphanFolders(
                projectId: project.id,
                keepIds: Set(folders.map(\.id.uuidString)),
                db: db
            )
        }
    }

    /// Applies only the entities that changed since the last successful save, in one
    /// transaction. Upsert SQL is shared with `persistProjectWorkspace`; deletions are
    /// limited to ids the caller removed (dependents before parents), so rows written by
    /// a remote pull that memory has not reloaded yet are never treated as orphans.
    func persistProjectWorkspaceDelta(project: Project, delta: ProjectWorkspaceDelta) throws {
        try dbQueue.write { db in
            try Self.upsertProject(project, db: db)
            try Self.upsertFolders(delta.upsertFolders, db: db)
            try Self.upsertDrawingsAndCalibrations(delta.upsertDrawings, db: db)
            try Self.insertMissingParentDrawings(delta.ensureParentDrawings, db: db)
            try Self.upsertAreas(delta.upsertAreas, db: db)
            try Self.upsertIssuesAndPhotos(delta.upsertIssues, projectId: project.id, db: db)

            let projectIdString = project.id.uuidString
            for (table, ids) in [
                ("issues", delta.deletedIssueIds),
                ("areas", delta.deletedAreaIds),
                ("drawings", delta.deletedDrawingIds),
                ("drawing_folders", delta.deletedFolderIds)
            ] {
                for id in ids {
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE id = ? AND project_id = ?",
                        arguments: [id.uuidString, projectIdString]
                    )
                }
            }
        }
    }

    /// Writes a parent drawing (with its in-memory calibrations) only when no row with its id
    /// exists. An existing row — possibly newer from a remote pull — is left untouched, so
    /// pulled name / revision / folder links are never reverted from a stale memory copy.
    /// A row missing here was removed by a pull after memory loaded it; restoring it keeps
    /// the user's new child, and later pulls keep it because it now has local dependents.
    static func insertMissingParentDrawings(_ drawings: [Drawing], db: Database) throws {
        for drawing in drawings {
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM drawings WHERE id = ?)",
                arguments: [drawing.id.uuidString]
            ) ?? false
            if !exists {
                try upsertDrawingsAndCalibrations([drawing], db: db)
            }
        }
    }

    // MARK: - Shared writers

    static func upsertProject(_ project: Project, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO projects (id, name, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name
            """,
            arguments: [
                project.id.uuidString,
                project.name,
                SQLiteDateCoding.string(from: project.createdDate)
            ]
        )
    }

    static func upsertFolders(_ folders: [DrawingFolder], db: Database) throws {
        for folder in folders {
            try db.execute(
                sql: """
                INSERT INTO drawing_folders
                  (id, project_id, parent_folder_id, name, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  project_id = excluded.project_id,
                  parent_folder_id = excluded.parent_folder_id,
                  name = excluded.name,
                  sort_order = excluded.sort_order,
                  created_at = excluded.created_at
                """,
                arguments: [
                    folder.id.uuidString,
                    folder.projectId.uuidString,
                    folder.parentFolderId?.uuidString,
                    folder.name,
                    folder.sortOrder,
                    SQLiteDateCoding.string(from: folder.createdDate)
                ]
            )
        }
    }

    static func upsertDrawingsAndCalibrations(_ drawings: [Drawing], db: Database) throws {
        for drawing in drawings {
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

            let keepCalIds = Set(drawing.calibrations.map(\.id.uuidString))
            for cal in drawing.calibrations {
                try db.execute(
                    sql: """
                    INSERT INTO page_calibrations
                      (id, drawing_id, page_index,
                       point_a_x, point_a_y, point_b_x, point_b_y,
                       real_distance_mm, entered_unit, entered_value,
                       mm_per_pdf_unit, calibrated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      drawing_id = excluded.drawing_id,
                      page_index = excluded.page_index,
                      point_a_x = excluded.point_a_x,
                      point_a_y = excluded.point_a_y,
                      point_b_x = excluded.point_b_x,
                      point_b_y = excluded.point_b_y,
                      real_distance_mm = excluded.real_distance_mm,
                      entered_unit = excluded.entered_unit,
                      entered_value = excluded.entered_value,
                      mm_per_pdf_unit = excluded.mm_per_pdf_unit,
                      calibrated_at = excluded.calibrated_at
                    """,
                    arguments: [
                        cal.id.uuidString,
                        drawing.id.uuidString,
                        cal.pageIndex,
                        cal.pointA.x,
                        cal.pointA.y,
                        cal.pointB.x,
                        cal.pointB.y,
                        cal.realDistanceMM,
                        cal.enteredUnit.rawValue,
                        cal.enteredValue,
                        cal.mmPerPDFUnit,
                        SQLiteDateCoding.string(from: cal.calibratedDate)
                    ]
                )
            }

            let existingCalIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM page_calibrations WHERE drawing_id = ?",
                arguments: [drawing.id.uuidString]
            )
            for id in existingCalIds where !keepCalIds.contains(id) {
                try db.execute(sql: "DELETE FROM page_calibrations WHERE id = ?", arguments: [id])
            }
        }
    }

    static func deleteOrphanFolders(projectId: UUID, keepIds: Set<String>, db: Database) throws {
        let existing = try String.fetchAll(
            db,
            sql: "SELECT id FROM drawing_folders WHERE project_id = ?",
            arguments: [projectId.uuidString]
        )
        for id in existing where !keepIds.contains(id) {
            try db.execute(sql: "DELETE FROM drawing_folders WHERE id = ?", arguments: [id])
        }
    }

    /// - Parameter requireNoDependents: when true, skip deleting drawings that still have
    ///   issues/areas (drawing-only persist path). When false, caller must have already
    ///   removed dependents.
    static func deleteOrphanDrawings(
        projectId: UUID,
        keepIds: Set<String>,
        requireNoDependents: Bool,
        db: Database
    ) throws {
        let existing = try String.fetchAll(
            db,
            sql: "SELECT id FROM drawings WHERE project_id = ?",
            arguments: [projectId.uuidString]
        )
        for id in existing where !keepIds.contains(id) {
            if requireNoDependents {
                let issueCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM issues WHERE drawing_id = ?",
                    arguments: [id]
                ) ?? 0
                let areaCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM areas WHERE drawing_id = ?",
                    arguments: [id]
                ) ?? 0
                if issueCount > 0 || areaCount > 0 {
                    continue
                }
            }
            try db.execute(sql: "DELETE FROM drawings WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Row mapping

    private static func folder(from row: Row) throws -> DrawingFolder {
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"])
        else {
            throw DrawingMetadataStoreError.invalidRow("drawing_folders")
        }
        let parentRaw: String? = row["parent_folder_id"]
        let createdRaw: String = row["created_at"]
        return DrawingFolder(
            id: id,
            projectId: projectId,
            parentFolderId: parentRaw.flatMap(UUID.init(uuidString:)),
            name: row["name"],
            sortOrder: row["sort_order"],
            createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date()
        )
    }

    static func fetchDrawingRow(id: UUID, db: Database) throws -> Drawing? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, project_id, folder_id, name, file_name, page_count, created_at,
                   revision, discipline, location, drawing_date
            FROM drawings
            WHERE id = ?
            """,
            arguments: [id.uuidString]
        )
        guard let row else { return nil }
        var drawing = try drawing(from: row)
        drawing.calibrations = try fetchCalibrations(drawingId: drawing.id, db: db)
        return drawing
    }

    private static func drawing(from row: Row) throws -> Drawing {
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"])
        else {
            throw DrawingMetadataStoreError.invalidRow("drawings")
        }
        let folderRaw: String? = row["folder_id"]
        let createdRaw: String = row["created_at"]
        let drawingDateRaw: String? = row["drawing_date"]
        return Drawing(
            id: id,
            projectId: projectId,
            folderId: folderRaw.flatMap(UUID.init(uuidString:)),
            name: row["name"],
            fileName: row["file_name"],
            pageCount: row["page_count"],
            createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date(),
            revision: row["revision"],
            discipline: row["discipline"],
            location: row["location"],
            drawingDate: drawingDateRaw.flatMap(SQLiteDateCoding.date(from:)),
            calibrations: []
        )
    }

    private static func fetchCalibrations(drawingId: UUID, db: Database) throws -> [PageCalibration] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, page_index, point_a_x, point_a_y, point_b_x, point_b_y,
                   real_distance_mm, entered_unit, entered_value, mm_per_pdf_unit, calibrated_at
            FROM page_calibrations
            WHERE drawing_id = ?
            ORDER BY page_index ASC
            """,
            arguments: [drawingId.uuidString]
        )
        return try rows.map(calibration(from:))
    }

    /// Calibrations for every drawing of a project, grouped by `drawing_id` string and
    /// ordered by `page_index` within each drawing (same order as `fetchCalibrations`).
    private static func fetchCalibrationsByDrawing(projectId: UUID, db: Database) throws -> [String: [PageCalibration]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT c.id, c.drawing_id, c.page_index, c.point_a_x, c.point_a_y, c.point_b_x, c.point_b_y,
                   c.real_distance_mm, c.entered_unit, c.entered_value, c.mm_per_pdf_unit, c.calibrated_at
            FROM page_calibrations c
            JOIN drawings d ON d.id = c.drawing_id
            WHERE d.project_id = ?
            ORDER BY c.drawing_id ASC, c.page_index ASC
            """,
            arguments: [projectId.uuidString]
        )
        var grouped: [String: [PageCalibration]] = [:]
        for row in rows {
            let drawingId: String = row["drawing_id"]
            grouped[drawingId, default: []].append(try calibration(from: row))
        }
        return grouped
    }

    private static func calibration(from row: Row) throws -> PageCalibration {
        guard let id = UUID(uuidString: row["id"]) else {
            throw DrawingMetadataStoreError.invalidRow("page_calibrations")
        }
        let unitRaw: String = row["entered_unit"]
        let unit = LengthUnit(rawValue: unitRaw) ?? .mm
        let calibratedRaw: String = row["calibrated_at"]
        return PageCalibration(
            id: id,
            pageIndex: row["page_index"],
            pointA: PDFPoint(x: row["point_a_x"], y: row["point_a_y"]),
            pointB: PDFPoint(x: row["point_b_x"], y: row["point_b_y"]),
            realDistanceMM: row["real_distance_mm"],
            enteredUnit: unit,
            enteredValue: row["entered_value"],
            mmPerPDFUnit: row["mm_per_pdf_unit"],
            calibratedDate: SQLiteDateCoding.date(from: calibratedRaw) ?? Date()
        )
    }
}

/// Workspace entities changed since the last successful SQLite save (see `AppStore.persist`).
struct ProjectWorkspaceDelta {
    var upsertFolders: [DrawingFolder] = []
    var upsertDrawings: [Drawing] = []
    var upsertAreas: [Area] = []
    var upsertIssues: [Issue] = []
    /// Parents of `upsertIssues` / `upsertAreas`; inserted only if missing, never overwritten.
    var ensureParentDrawings: [Drawing] = []
    var deletedIssueIds: [UUID] = []
    var deletedAreaIds: [UUID] = []
    var deletedDrawingIds: [UUID] = []
    var deletedFolderIds: [UUID] = []

    var isEmpty: Bool {
        upsertFolders.isEmpty && upsertDrawings.isEmpty && upsertAreas.isEmpty && upsertIssues.isEmpty
            && ensureParentDrawings.isEmpty
            && deletedIssueIds.isEmpty && deletedAreaIds.isEmpty
            && deletedDrawingIds.isEmpty && deletedFolderIds.isEmpty
    }
}

enum DrawingMetadataStoreError: LocalizedError {
    case invalidRow(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            return "Invalid SQLite row in \(table)"
        }
    }
}
