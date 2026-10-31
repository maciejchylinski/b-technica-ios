import Foundation
import GRDB

/// SQLite read/write for drawing folders, drawings, and page calibrations.
/// Authoritative after JSON → SQLite import; PDF bytes stay on disk under `Drawings/`.
extension AppDatabase {
    /// Ensures the local `projects` row exists (FK parent for folders/drawings).
    func ensureProject(_ project: Project) throws {
        try dbQueue.write { db in
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

            var result: [Drawing] = []
            result.reserveCapacity(drawingRows.count)
            for row in drawingRows {
                var drawing = try Self.drawing(from: row)
                drawing.calibrations = try Self.fetchCalibrations(drawingId: drawing.id, db: db)
                result.append(drawing)
            }
            return result
        }
    }

    /// Replaces the project's folder + drawing tree in one transaction.
    /// Preserves drawing UUIDs and relative `file_name` values; does not touch PDF files.
    func replaceFoldersAndDrawings(
        project: Project,
        folders: [DrawingFolder],
        drawings: [Drawing]
    ) throws {
        try dbQueue.write { db in
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

            let projectKey = project.id.uuidString
            let keepFolderIds = Set(folders.map { $0.id.uuidString })
            let keepDrawingIds = Set(drawings.map { $0.id.uuidString })

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

                try db.execute(
                    sql: "DELETE FROM page_calibrations WHERE drawing_id = ?",
                    arguments: [drawing.id.uuidString]
                )
                for cal in drawing.calibrations {
                    try db.execute(
                        sql: """
                        INSERT INTO page_calibrations
                          (id, drawing_id, page_index,
                           point_a_x, point_a_y, point_b_x, point_b_y,
                           real_distance_mm, entered_unit, entered_value,
                           mm_per_pdf_unit, calibrated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            }

            // Remove drawings no longer present (calibrations cascade).
            let existingDrawingIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM drawings WHERE project_id = ?",
                arguments: [projectKey]
            )
            for id in existingDrawingIds where !keepDrawingIds.contains(id) {
                try db.execute(sql: "DELETE FROM drawings WHERE id = ?", arguments: [id])
            }

            let existingFolderIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM drawing_folders WHERE project_id = ?",
                arguments: [projectKey]
            )
            for id in existingFolderIds where !keepFolderIds.contains(id) {
                try db.execute(sql: "DELETE FROM drawing_folders WHERE id = ?", arguments: [id])
            }
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
        return try rows.map { row in
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
