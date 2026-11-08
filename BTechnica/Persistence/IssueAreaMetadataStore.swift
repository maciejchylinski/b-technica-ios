import Foundation
import GRDB

/// SQLite read/write for areas, issues, and issue photo metadata.
/// Authoritative after JSON → SQLite import; image bytes stay on disk under `IssuePhotos/`.
extension AppDatabase {
    func fetchAreas(projectId: UUID) throws -> [Area] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, drawing_id, page_index, name, vertices_json,
                       color, opacity, is_visible, created_at, updated_at
                FROM areas
                WHERE project_id = ?
                ORDER BY created_at ASC, name ASC
                """,
                arguments: [projectId.uuidString]
            )
            return try rows.map { try Self.area(from: $0) }
        }
    }

    func fetchIssues(projectId: UUID) throws -> [Issue] {
        try dbQueue.read { db in
            let issueRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, drawing_id, page_index, pdf_x, pdf_y, area_id,
                       number, title, details, status, discipline, contractor, created_at
                FROM issues
                WHERE project_id = ?
                ORDER BY number ASC, created_at ASC
                """,
                arguments: [projectId.uuidString]
            )

            // One grouped photo query instead of one query per issue (N+1 on workspace open).
            let photosByIssue = try Self.fetchPhotosByIssue(projectId: projectId, db: db)
            var result: [Issue] = []
            result.reserveCapacity(issueRows.count)
            for row in issueRows {
                var issue = try Self.issue(from: row)
                issue.photos = photosByIssue[issue.id.uuidString] ?? []
                result.append(issue)
            }
            return result
        }
    }

    /// Upserts areas/issues/photos and removes intentional orphans.
    /// Prefer `persistProjectWorkspace` when drawings are also changing in the same save.
    func replaceAreasAndIssues(
        project: Project,
        areas: [Area],
        issues: [Issue]
    ) throws {
        try dbQueue.write { db in
            try Self.upsertProject(project, db: db)
            try Self.upsertAreas(areas, db: db)
            try Self.upsertIssuesAndPhotos(issues, projectId: project.id, db: db)
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
        }
    }

    // MARK: - Shared writers

    static func upsertAreas(_ areas: [Area], db: Database) throws {
        for area in areas {
            let verticesJSON = try encodeVertices(area.vertices)
            try db.execute(
                sql: """
                INSERT INTO areas
                  (id, project_id, drawing_id, page_index, name, vertices_json,
                   color, opacity, is_visible, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  project_id = excluded.project_id,
                  drawing_id = excluded.drawing_id,
                  page_index = excluded.page_index,
                  name = excluded.name,
                  vertices_json = excluded.vertices_json,
                  color = excluded.color,
                  opacity = excluded.opacity,
                  is_visible = excluded.is_visible,
                  created_at = excluded.created_at,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    area.id.uuidString,
                    area.projectId.uuidString,
                    area.drawingId.uuidString,
                    area.pageIndex,
                    area.name,
                    verticesJSON,
                    area.color,
                    area.opacity,
                    area.isVisible,
                    SQLiteDateCoding.string(from: area.createdDate),
                    SQLiteDateCoding.string(from: area.updatedDate)
                ]
            )
        }
    }

    static func upsertIssuesAndPhotos(_ issues: [Issue], projectId: UUID, db: Database) throws {
        for issue in issues {
            try db.execute(
                sql: """
                INSERT INTO issues
                  (id, project_id, drawing_id, page_index, pdf_x, pdf_y, area_id,
                   number, title, details, status, discipline, contractor, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  project_id = excluded.project_id,
                  drawing_id = excluded.drawing_id,
                  page_index = excluded.page_index,
                  pdf_x = excluded.pdf_x,
                  pdf_y = excluded.pdf_y,
                  area_id = excluded.area_id,
                  number = excluded.number,
                  title = excluded.title,
                  details = excluded.details,
                  status = excluded.status,
                  discipline = excluded.discipline,
                  contractor = excluded.contractor,
                  created_at = excluded.created_at
                """,
                arguments: [
                    issue.id.uuidString,
                    projectId.uuidString,
                    issue.drawingId.uuidString,
                    issue.pageIndex,
                    issue.pdfX,
                    issue.pdfY,
                    issue.areaId?.uuidString,
                    issue.number,
                    issue.title,
                    issue.details,
                    issue.status.rawValue,
                    issue.discipline,
                    issue.contractor,
                    SQLiteDateCoding.string(from: issue.createdDate)
                ]
            )

            let keepPhotoIds = Set(issue.photos.map(\.id.uuidString))
            for photo in issue.photos {
                try db.execute(
                    sql: """
                    INSERT INTO issue_photos (id, issue_id, file_name, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      issue_id = excluded.issue_id,
                      file_name = excluded.file_name,
                      created_at = excluded.created_at
                    """,
                    arguments: [
                        photo.id.uuidString,
                        issue.id.uuidString,
                        photo.fileName,
                        SQLiteDateCoding.string(from: photo.createdDate)
                    ]
                )
            }

            let existingPhotoIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM issue_photos WHERE issue_id = ?",
                arguments: [issue.id.uuidString]
            )
            for id in existingPhotoIds where !keepPhotoIds.contains(id) {
                try db.execute(sql: "DELETE FROM issue_photos WHERE id = ?", arguments: [id])
            }
        }
    }

    static func deleteOrphanIssues(projectId: UUID, keepIds: Set<String>, db: Database) throws {
        let existing = try String.fetchAll(
            db,
            sql: "SELECT id FROM issues WHERE project_id = ?",
            arguments: [projectId.uuidString]
        )
        for id in existing where !keepIds.contains(id) {
            try db.execute(sql: "DELETE FROM issues WHERE id = ?", arguments: [id])
        }
    }

    static func deleteOrphanAreas(projectId: UUID, keepIds: Set<String>, db: Database) throws {
        let existing = try String.fetchAll(
            db,
            sql: "SELECT id FROM areas WHERE project_id = ?",
            arguments: [projectId.uuidString]
        )
        for id in existing where !keepIds.contains(id) {
            try db.execute(sql: "DELETE FROM areas WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Row mapping

    private static func area(from row: Row) throws -> Area {
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"]),
              let drawingId = UUID(uuidString: row["drawing_id"])
        else {
            throw IssueAreaMetadataStoreError.invalidRow("areas")
        }
        let verticesJSON: String = row["vertices_json"]
        let createdRaw: String = row["created_at"]
        let updatedRaw: String = row["updated_at"]
        let created = SQLiteDateCoding.date(from: createdRaw) ?? Date()
        return Area(
            id: id,
            projectId: projectId,
            drawingId: drawingId,
            pageIndex: row["page_index"],
            name: row["name"],
            vertices: try decodeVertices(verticesJSON),
            color: row["color"],
            opacity: row["opacity"],
            isVisible: row["is_visible"],
            createdDate: created,
            updatedDate: SQLiteDateCoding.date(from: updatedRaw) ?? created
        )
    }

    private static func issue(from row: Row) throws -> Issue {
        guard let id = UUID(uuidString: row["id"]),
              let drawingId = UUID(uuidString: row["drawing_id"])
        else {
            throw IssueAreaMetadataStoreError.invalidRow("issues")
        }
        let areaRaw: String? = row["area_id"]
        let statusRaw: String = row["status"]
        let createdRaw: String = row["created_at"]
        return Issue(
            id: id,
            drawingId: drawingId,
            pageIndex: row["page_index"],
            pdfX: row["pdf_x"],
            pdfY: row["pdf_y"],
            areaId: areaRaw.flatMap(UUID.init(uuidString:)),
            number: row["number"],
            title: row["title"],
            details: row["details"],
            status: IssueStatus(rawValue: statusRaw) ?? .open,
            discipline: row["discipline"],
            contractor: row["contractor"],
            createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date(),
            photos: []
        )
    }

    /// Photo metadata for every issue of a project, grouped by `issue_id` string and
    /// ordered by `created_at` within each issue (same order as the former per-issue query).
    private static func fetchPhotosByIssue(projectId: UUID, db: Database) throws -> [String: [IssuePhoto]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT p.id, p.issue_id, p.file_name, p.created_at
            FROM issue_photos p
            JOIN issues i ON i.id = p.issue_id
            WHERE i.project_id = ?
            ORDER BY p.issue_id ASC, p.created_at ASC
            """,
            arguments: [projectId.uuidString]
        )
        var grouped: [String: [IssuePhoto]] = [:]
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else {
                throw IssueAreaMetadataStoreError.invalidRow("issue_photos")
            }
            let issueId: String = row["issue_id"]
            let createdRaw: String = row["created_at"]
            grouped[issueId, default: []].append(IssuePhoto(
                id: id,
                fileName: row["file_name"],
                createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date()
            ))
        }
        return grouped
    }

    static func encodeVertices(_ vertices: [PDFPoint]) throws -> String {
        struct PointDTO: Encodable {
            let x: Double
            let y: Double
        }
        let payload = vertices.map { PointDTO(x: $0.x, y: $0.y) }
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw IssueAreaMetadataStoreError.invalidVertices
        }
        return string
    }

    static func decodeVertices(_ json: String) throws -> [PDFPoint] {
        struct PointDTO: Decodable {
            let x: Double
            let y: Double
        }
        guard let data = json.data(using: .utf8) else {
            throw IssueAreaMetadataStoreError.invalidVertices
        }
        let points = try JSONDecoder().decode([PointDTO].self, from: data)
        return points.map { PDFPoint(x: $0.x, y: $0.y) }
    }
}

enum IssueAreaMetadataStoreError: LocalizedError {
    case invalidRow(String)
    case invalidVertices

    var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            return "Invalid SQLite row in \(table)"
        case .invalidVertices:
            return "Invalid area vertices JSON"
        }
    }
}
