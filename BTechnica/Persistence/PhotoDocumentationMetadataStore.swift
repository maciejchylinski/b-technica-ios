import Foundation
import GRDB

/// SQLite read/write for project photo documentation and albums.
/// Every row is scoped by `project_id`; drawing / area / issue / album links are verified
/// to belong to the same project inside the write transaction.
extension AppDatabase {
    func fetchProjectPhotos(projectId: UUID) throws -> [ProjectPhoto] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM project_photos WHERE project_id = ? ORDER BY taken_at DESC, created_at DESC",
                arguments: [projectId.uuidString]
            ).map(Self.projectPhoto(from:))
        }
    }

    func fetchProjectPhotos(issueId: UUID) throws -> [ProjectPhoto] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM project_photos WHERE issue_id = ? ORDER BY taken_at ASC",
                arguments: [issueId.uuidString]
            ).map(Self.projectPhoto(from:))
        }
    }

    func fetchPhotoAlbums(projectId: UUID) throws -> [PhotoAlbum] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM photo_albums WHERE project_id = ?
                ORDER BY sort_order ASC, name COLLATE NOCASE ASC
                """,
                arguments: [projectId.uuidString]
            ).map(Self.photoAlbum(from:))
        }
    }

    /// Inserts or updates photos in one transaction.
    func persistProjectPhotos(_ photos: [ProjectPhoto]) throws {
        try dbQueue.write { db in
            for photo in photos {
                try Self.validateLinks(of: photo, db: db)
                try db.execute(
                    sql: """
                    INSERT INTO project_photos
                      (id, project_id, album_id, file_name, thumbnail_file_name, title, description,
                       taken_at, drawing_id, page_index, area_id, issue_id, pixel_width, pixel_height,
                       byte_size, sync_status, remote_storage_path, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      album_id = excluded.album_id,
                      thumbnail_file_name = excluded.thumbnail_file_name,
                      title = excluded.title,
                      description = excluded.description,
                      taken_at = excluded.taken_at,
                      drawing_id = excluded.drawing_id,
                      page_index = excluded.page_index,
                      area_id = excluded.area_id,
                      issue_id = excluded.issue_id,
                      updated_at = excluded.updated_at
                    WHERE project_photos.project_id = excluded.project_id
                    """,
                    arguments: [
                        photo.id.uuidString, photo.projectId.uuidString, photo.albumId?.uuidString,
                        photo.fileName, photo.thumbnailFileName, photo.title, photo.description,
                        SQLiteDateCoding.string(from: photo.takenDate), photo.drawingId?.uuidString,
                        photo.pageIndex, photo.areaId?.uuidString, photo.issueId?.uuidString,
                        photo.pixelWidth, photo.pixelHeight, photo.byteSize, photo.syncStatus,
                        SQLiteDateCoding.string(from: photo.createdDate),
                        SQLiteDateCoding.string(from: photo.updatedDate)
                    ]
                )
            }
        }
    }

    /// Deletes photo rows and returns the relative file paths that are no longer referenced.
    func deleteProjectPhotos(ids: [UUID], projectId: UUID) throws -> [String] {
        try dbQueue.write { db in
            var files: [String] = []
            for id in ids {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT file_name, thumbnail_file_name FROM project_photos WHERE id = ? AND project_id = ?",
                    arguments: [id.uuidString, projectId.uuidString]
                ) else { continue }
                try db.execute(sql: "DELETE FROM project_photos WHERE id = ?", arguments: [id.uuidString])
                let file: String = row["file_name"]
                let thumb: String? = row["thumbnail_file_name"]
                let stillUsed = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM project_photos WHERE file_name = ? AND project_id = ?)",
                    arguments: [file, projectId.uuidString]
                ) ?? false
                if !stillUsed {
                    files.append(file)
                    if let thumb { files.append(thumb) }
                }
            }
            return files
        }
    }

    func persistPhotoAlbum(_ album: PhotoAlbum) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO photo_albums (id, project_id, name, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  sort_order = excluded.sort_order,
                  updated_at = excluded.updated_at
                WHERE photo_albums.project_id = excluded.project_id
                """,
                arguments: [
                    album.id.uuidString, album.projectId.uuidString, album.name, album.sortOrder,
                    SQLiteDateCoding.string(from: album.createdDate),
                    SQLiteDateCoding.string(from: album.updatedDate)
                ]
            )
        }
    }

    /// Deletes an album; its photos stay in the project without an album.
    func deletePhotoAlbum(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM photo_albums WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    /// Moves photos into an album (or out of any album when `albumId` is nil).
    func movePhotos(ids: [UUID], toAlbum albumId: UUID?, projectId: UUID) throws {
        try dbQueue.write { db in
            if let albumId {
                guard try String.fetchOne(
                    db,
                    sql: "SELECT project_id FROM photo_albums WHERE id = ?",
                    arguments: [albumId.uuidString]
                ) == projectId.uuidString else {
                    throw PhotoDocumentationError.crossProjectLink("album")
                }
            }
            let now = SQLiteDateCoding.string(from: Date())
            for id in ids {
                try db.execute(
                    sql: "UPDATE project_photos SET album_id = ?, updated_at = ? WHERE id = ? AND project_id = ?",
                    arguments: [albumId?.uuidString, now, id.uuidString, projectId.uuidString]
                )
            }
        }
    }

    // MARK: - Private

    private static func validateLinks(of photo: ProjectPhoto, db: Database) throws {
        let project = photo.projectId.uuidString
        let checks: [(table: String, id: UUID?, label: String)] = [
            ("photo_albums", photo.albumId, "album"),
            ("drawings", photo.drawingId, "drawing"),
            ("areas", photo.areaId, "area"),
            ("issues", photo.issueId, "issue")
        ]
        for check in checks {
            guard let id = check.id else { continue }
            let owner = try String.fetchOne(
                db,
                sql: "SELECT project_id FROM \(check.table) WHERE id = ?",
                arguments: [id.uuidString]
            )
            guard owner == project else { throw PhotoDocumentationError.crossProjectLink(check.label) }
        }
        if let areaId = photo.areaId, let drawingId = photo.drawingId {
            let areaDrawing = try String.fetchOne(
                db,
                sql: "SELECT drawing_id FROM areas WHERE id = ?",
                arguments: [areaId.uuidString]
            )
            guard areaDrawing == drawingId.uuidString else {
                throw PhotoDocumentationError.crossProjectLink("area (different drawing)")
            }
        }
    }

    private static func projectPhoto(from row: Row) throws -> ProjectPhoto {
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"]) else {
            throw PhotoDocumentationError.invalidRow("project_photos")
        }
        func uuid(_ column: String) -> UUID? {
            let raw: String? = row[column]
            return raw.flatMap(UUID.init(uuidString:))
        }
        let takenRaw: String = row["taken_at"]
        let createdRaw: String = row["created_at"]
        let updatedRaw: String = row["updated_at"]
        let created = SQLiteDateCoding.date(from: createdRaw) ?? Date()
        return ProjectPhoto(
            id: id,
            projectId: projectId,
            albumId: uuid("album_id"),
            fileName: row["file_name"],
            thumbnailFileName: row["thumbnail_file_name"],
            title: row["title"],
            description: row["description"],
            takenDate: SQLiteDateCoding.date(from: takenRaw) ?? created,
            drawingId: uuid("drawing_id"),
            pageIndex: row["page_index"],
            areaId: uuid("area_id"),
            issueId: uuid("issue_id"),
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            byteSize: row["byte_size"],
            syncStatus: row["sync_status"],
            createdDate: created,
            updatedDate: SQLiteDateCoding.date(from: updatedRaw) ?? created
        )
    }

    private static func photoAlbum(from row: Row) throws -> PhotoAlbum {
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"]) else {
            throw PhotoDocumentationError.invalidRow("photo_albums")
        }
        let createdRaw: String = row["created_at"]
        let updatedRaw: String = row["updated_at"]
        let created = SQLiteDateCoding.date(from: createdRaw) ?? Date()
        return PhotoAlbum(
            id: id,
            projectId: projectId,
            name: row["name"],
            sortOrder: row["sort_order"],
            createdDate: created,
            updatedDate: SQLiteDateCoding.date(from: updatedRaw) ?? created
        )
    }
}

enum PhotoDocumentationError: LocalizedError {
    case invalidRow(String)
    case crossProjectLink(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let table): return "Invalid SQLite row in \(table)"
        case .crossProjectLink(let what): return "The selected \(what) belongs to another project."
        }
    }
}
