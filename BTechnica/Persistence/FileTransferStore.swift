import Foundation
import GRDB

/// Entity kinds that may appear in `file_transfers`. Drawing PDFs are first.
enum FileTransferEntityType: String, Equatable {
    case drawing = "drawing"
}

/// Transfer direction stored in `file_transfers.direction`.
enum FileTransferDirection: String, Equatable {
    case upload
    case download
}

/// Durable transfer status. `completed` is set only after confirmed remote success.
enum FileTransferStatus: String, Equatable {
    case pending
    case uploading
    case completed
    case error
}

/// One durable file transfer row. `remotePath` is assigned at enqueue and never changes,
/// so retries target the same Storage object (`{project_id}/{revision_id}.pdf`).
struct FileTransfer: Equatable, Identifiable {
    var id: UUID
    var entityType: FileTransferEntityType
    var entityId: UUID
    var localRelativePath: String
    var remotePath: String?
    var direction: FileTransferDirection
    var status: FileTransferStatus
    var bytesTotal: Int64?
    var bytesDone: Int64
    var error: String?
    var createdAt: Date
    var updatedAt: Date
}

extension AppDatabase {
    /// Relative path under the per-user root for a drawing PDF.
    static func drawingPDFLocalRelativePath(projectId: UUID, fileName: String) -> String {
        "Projects/\(projectId.uuidString)/Drawings/\(fileName)"
    }

    /// Stable Storage object key inside the `drawings` bucket (no bucket prefix).
    static func drawingPDFRemotePath(projectId: UUID, revisionId: UUID) -> String {
        "\(projectId.uuidString)/\(revisionId.uuidString).pdf"
    }

    /// Enqueues a drawing PDF upload, or returns the existing incomplete/completed row.
    /// Does not upload. Assigns a stable `remotePath` on first insert.
    @discardableResult
    func enqueueDrawingPDFUpload(
        drawingId: UUID,
        projectId: UUID,
        fileName: String,
        bytesTotal: Int64?,
        transferId: UUID = UUID(),
        revisionId: UUID = UUID(),
        now: Date = Date()
    ) throws -> FileTransfer {
        let localRelativePath = Self.drawingPDFLocalRelativePath(
            projectId: projectId,
            fileName: fileName
        )
        let remotePath = Self.drawingPDFRemotePath(projectId: projectId, revisionId: revisionId)

        return try dbQueue.write { db in
            if let existing = try Self.fetchDrawingUpload(drawingId: drawingId, db: db) {
                return existing
            }

            let stamp = SQLiteDateCoding.string(from: now)
            try db.execute(
                sql: """
                INSERT INTO file_transfers
                  (id, entity_type, entity_id, local_relative_path, remote_path,
                   direction, status, bytes_total, bytes_done, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
                """,
                arguments: [
                    transferId.uuidString,
                    FileTransferEntityType.drawing.rawValue,
                    drawingId.uuidString,
                    localRelativePath,
                    remotePath,
                    FileTransferDirection.upload.rawValue,
                    FileTransferStatus.pending.rawValue,
                    bytesTotal,
                    stamp,
                    stamp
                ]
            )
            return FileTransfer(
                id: transferId,
                entityType: .drawing,
                entityId: drawingId,
                localRelativePath: localRelativePath,
                remotePath: remotePath,
                direction: .upload,
                status: .pending,
                bytesTotal: bytesTotal,
                bytesDone: 0,
                error: nil,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    /// Incomplete drawing PDF uploads for a project (pending / uploading / error), oldest first.
    func fetchPendingDrawingPDFUploads(projectId: UUID) throws -> [FileTransfer] {
        let prefix = "\(projectId.uuidString)/"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                       direction, status, bytes_total, bytes_done, error, created_at, updated_at
                FROM file_transfers
                WHERE entity_type = ?
                  AND direction = ?
                  AND status IN (?, ?, ?)
                  AND remote_path LIKE ?
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [
                    FileTransferEntityType.drawing.rawValue,
                    FileTransferDirection.upload.rawValue,
                    FileTransferStatus.pending.rawValue,
                    FileTransferStatus.uploading.rawValue,
                    FileTransferStatus.error.rawValue,
                    "\(prefix)%"
                ]
            )
            return try rows.map { try Self.fileTransfer(from: $0) }
        }
    }

    func fetchFileTransfer(id: UUID) throws -> FileTransfer? {
        try dbQueue.read { db in
            try Self.fetchFileTransfer(id: id, db: db)
        }
    }

    /// Completed or incomplete drawing PDF upload row for a drawing id (at most one).
    func fetchDrawingPDFUpload(drawingId: UUID) throws -> FileTransfer? {
        try dbQueue.read { db in
            try Self.fetchDrawingUpload(drawingId: drawingId, db: db)
        }
    }

    /// Completed drawing PDF uploads for a project (for metadata reconcile).
    func fetchCompletedDrawingPDFUploads(projectId: UUID) throws -> [FileTransfer] {
        let prefix = "\(projectId.uuidString)/"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                       direction, status, bytes_total, bytes_done, error, created_at, updated_at
                FROM file_transfers
                WHERE entity_type = ?
                  AND direction = ?
                  AND status = ?
                  AND remote_path LIKE ?
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [
                    FileTransferEntityType.drawing.rawValue,
                    FileTransferDirection.upload.rawValue,
                    FileTransferStatus.completed.rawValue,
                    "\(prefix)%"
                ]
            )
            return try rows.map { try Self.fileTransfer(from: $0) }
        }
    }

    func markFileTransferUploading(id: UUID, now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE file_transfers
                SET status = ?, error = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    FileTransferStatus.uploading.rawValue,
                    SQLiteDateCoding.string(from: now),
                    id.uuidString
                ]
            )
        }
    }

    /// Marks complete only after the caller confirmed remote success. Local file is untouched.
    func markFileTransferCompleted(
        id: UUID,
        bytesDone: Int64?,
        now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE file_transfers
                SET status = ?,
                    bytes_done = COALESCE(?, bytes_total, bytes_done),
                    error = NULL,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    FileTransferStatus.completed.rawValue,
                    bytesDone,
                    SQLiteDateCoding.string(from: now),
                    id.uuidString
                ]
            )
        }
    }

    func markFileTransferError(
        id: UUID,
        error: String,
        now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE file_transfers
                SET status = ?, error = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    FileTransferStatus.error.rawValue,
                    error,
                    SQLiteDateCoding.string(from: now),
                    id.uuidString
                ]
            )
        }
    }

    /// Pending (or existing) download row for a remote drawing PDF path.
    /// Does not download bytes and never marks the transfer completed.
    func fetchDrawingPDFDownload(drawingId: UUID) throws -> FileTransfer? {
        try dbQueue.read { db in
            try Self.fetchDrawingDownload(drawingId: drawingId, db: db)
        }
    }

    /// Incomplete drawing PDF downloads for a project (pending / uploading / error), oldest first.
    func fetchPendingDrawingPDFDownloads(projectId: UUID) throws -> [FileTransfer] {
        let prefix = "\(projectId.uuidString)/"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                       direction, status, bytes_total, bytes_done, error, created_at, updated_at
                FROM file_transfers
                WHERE entity_type = ?
                  AND direction = ?
                  AND status IN (?, ?, ?)
                  AND remote_path LIKE ?
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [
                    FileTransferEntityType.drawing.rawValue,
                    FileTransferDirection.download.rawValue,
                    FileTransferStatus.pending.rawValue,
                    FileTransferStatus.uploading.rawValue,
                    FileTransferStatus.error.rawValue,
                    "\(prefix)%"
                ]
            )
            return try rows.map { try Self.fileTransfer(from: $0) }
        }
    }

    /// Ensures a pending download row exists for `drawingId`, reusing a completed upload's
    /// remote path when the download placeholder is missing. Does not download bytes.
    @discardableResult
    func ensureDrawingPDFDownloadQueued(
        drawingId: UUID,
        projectId: UUID,
        fileName: String,
        now: Date = Date()
    ) throws -> FileTransfer? {
        try dbQueue.write { db in
            if let existing = try Self.fetchDrawingDownload(drawingId: drawingId, db: db) {
                return existing
            }
            guard let upload = try Self.fetchDrawingUpload(drawingId: drawingId, db: db),
                  let remotePath = upload.remotePath,
                  !remotePath.isEmpty
            else {
                return nil
            }
            try Self.upsertPendingDrawingPDFDownload(
                drawingId: drawingId,
                projectId: projectId,
                fileName: fileName,
                remotePath: remotePath,
                now: now,
                db: db
            )
            return try Self.fetchDrawingDownload(drawingId: drawingId, db: db)
        }
    }

    // MARK: - Internals

    /// Upserts a pending download placeholder so remote PDF paths survive pull without
    /// implying the local file is available. Does not touch upload rows.
    static func upsertPendingDrawingPDFDownload(
        drawingId: UUID,
        projectId: UUID,
        fileName: String,
        remotePath: String,
        transferId: UUID = UUID(),
        now: Date = Date(),
        db: Database
    ) throws {
        let localRelativePath = drawingPDFLocalRelativePath(
            projectId: projectId,
            fileName: fileName
        )
        if let existing = try fetchDrawingDownload(drawingId: drawingId, db: db) {
            // Keep completed downloads intact; refresh path/name on incomplete rows only.
            if existing.status == .completed { return }
            try db.execute(
                sql: """
                UPDATE file_transfers
                SET local_relative_path = ?,
                    remote_path = ?,
                    status = ?,
                    error = NULL,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    localRelativePath,
                    remotePath,
                    FileTransferStatus.pending.rawValue,
                    SQLiteDateCoding.string(from: now),
                    existing.id.uuidString
                ]
            )
            return
        }

        let stamp = SQLiteDateCoding.string(from: now)
        try db.execute(
            sql: """
            INSERT INTO file_transfers
              (id, entity_type, entity_id, local_relative_path, remote_path,
               direction, status, bytes_total, bytes_done, error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?)
            """,
            arguments: [
                transferId.uuidString,
                FileTransferEntityType.drawing.rawValue,
                drawingId.uuidString,
                localRelativePath,
                remotePath,
                FileTransferDirection.download.rawValue,
                FileTransferStatus.pending.rawValue,
                stamp,
                stamp
            ]
        )
    }

    static func deleteDrawingDownloadTransfers(drawingId: UUID, db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM file_transfers
            WHERE entity_type = ?
              AND entity_id = ?
              AND direction = ?
            """,
            arguments: [
                FileTransferEntityType.drawing.rawValue,
                drawingId.uuidString,
                FileTransferDirection.download.rawValue
            ]
        )
    }

    static func fetchDrawingDownload(drawingId: UUID, db: Database) throws -> FileTransfer? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                   direction, status, bytes_total, bytes_done, error, created_at, updated_at
            FROM file_transfers
            WHERE entity_type = ?
              AND entity_id = ?
              AND direction = ?
            ORDER BY created_at ASC, id ASC
            LIMIT 1
            """,
            arguments: [
                FileTransferEntityType.drawing.rawValue,
                drawingId.uuidString,
                FileTransferDirection.download.rawValue
            ]
        )
        return try row.map { try fileTransfer(from: $0) }
    }

    static func fetchDrawingUpload(drawingId: UUID, db: Database) throws -> FileTransfer? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                   direction, status, bytes_total, bytes_done, error, created_at, updated_at
            FROM file_transfers
            WHERE entity_type = ?
              AND entity_id = ?
              AND direction = ?
            ORDER BY created_at ASC, id ASC
            LIMIT 1
            """,
            arguments: [
                FileTransferEntityType.drawing.rawValue,
                drawingId.uuidString,
                FileTransferDirection.upload.rawValue
            ]
        )
        return try row.map { try fileTransfer(from: $0) }
    }

    private static func fetchFileTransfer(id: UUID, db: Database) throws -> FileTransfer? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, entity_type, entity_id, local_relative_path, remote_path,
                   direction, status, bytes_total, bytes_done, error, created_at, updated_at
            FROM file_transfers
            WHERE id = ?
            """,
            arguments: [id.uuidString]
        )
        return try row.map { try fileTransfer(from: $0) }
    }

    private static func fileTransfer(from row: Row) throws -> FileTransfer {
        guard let id = UUID(uuidString: row["id"]),
              let entityId = UUID(uuidString: row["entity_id"])
        else {
            throw FileTransferStoreError.invalidRow
        }
        let entityRaw: String = row["entity_type"]
        let directionRaw: String = row["direction"]
        let statusRaw: String = row["status"]
        guard let entityType = FileTransferEntityType(rawValue: entityRaw),
              let direction = FileTransferDirection(rawValue: directionRaw),
              let status = FileTransferStatus(rawValue: statusRaw)
        else {
            throw FileTransferStoreError.invalidRow
        }
        let createdRaw: String = row["created_at"]
        let updatedRaw: String = row["updated_at"]
        let bytesDone: Int64 = row["bytes_done"]
        return FileTransfer(
            id: id,
            entityType: entityType,
            entityId: entityId,
            localRelativePath: row["local_relative_path"],
            remotePath: row["remote_path"],
            direction: direction,
            status: status,
            bytesTotal: row["bytes_total"],
            bytesDone: bytesDone,
            error: row["error"],
            createdAt: SQLiteDateCoding.date(from: createdRaw) ?? Date(),
            updatedAt: SQLiteDateCoding.date(from: updatedRaw) ?? Date()
        )
    }
}

enum FileTransferStoreError: LocalizedError {
    case invalidRow

    var errorDescription: String? {
        switch self {
        case .invalidRow:
            return "Invalid file_transfers row"
        }
    }
}
