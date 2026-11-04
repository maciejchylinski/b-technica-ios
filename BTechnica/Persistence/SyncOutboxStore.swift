import Foundation
import GRDB

/// Local sync outbox status for a queued mutation.
/// Pending/error rows live in `sync_outbox`; sent removes the row (retry-safe until then).
enum SyncOutboxStatus: String, Equatable {
    case pending
    case sent
    case error
}

/// Mutation kind stored in `sync_outbox.operation`.
enum SyncOutboxOperation: String, Equatable {
    case create
    case update
    case delete
}

/// Entity kinds that may appear in the outbox. Folders first; drawings after PDF upload;
/// areas after drawing page mappings exist.
enum SyncOutboxEntityType: String, Equatable {
    case drawingFolder = "drawing_folder"
    case drawing = "drawing"
    case area = "area"
}

/// One durable outbox row. `id` is the stable operation UUID used across retries.
struct SyncOutboxEntry: Equatable, Identifiable {
    var id: UUID
    var entityType: SyncOutboxEntityType
    var entityId: UUID
    var operation: SyncOutboxOperation
    var payloadJSON: String?
    var createdAt: Date
    var attemptCount: Int
    var lastError: String?
    var nextAttemptAt: Date?

    var status: SyncOutboxStatus {
        lastError == nil ? .pending : .error
    }
}

/// SQLite outbox enqueue + status helpers. No network calls.
extension AppDatabase {
    /// Pending/error rows in creation order (stable retries preserve FIFO).
    func fetchOutboxEntries(readyForAttemptAt now: Date = Date()) throws -> [SyncOutboxEntry] {
        let nowString = SQLiteDateCoding.string(from: now)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity_type, entity_id, operation, payload_json,
                       created_at, attempt_count, last_error, next_attempt_at
                FROM sync_outbox
                WHERE last_error IS NULL
                   OR next_attempt_at IS NULL
                   OR next_attempt_at <= ?
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [nowString]
            )
            return try rows.map { try Self.outboxEntry(from: $0) }
        }
    }

    func fetchAllOutboxEntries() throws -> [SyncOutboxEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity_type, entity_id, operation, payload_json,
                       created_at, attempt_count, last_error, next_attempt_at
                FROM sync_outbox
                ORDER BY created_at ASC, id ASC
                """
            )
            return try rows.map { try Self.outboxEntry(from: $0) }
        }
    }

    /// Marks an operation sent by removing it (idempotent if already gone).
    func markOutboxSent(operationId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM sync_outbox WHERE id = ?",
                arguments: [operationId.uuidString]
            )
        }
    }

    /// Records a failed attempt; row stays queued for ordered retry.
    func markOutboxError(
        operationId: UUID,
        error: String,
        nextAttemptAt: Date?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_outbox
                SET attempt_count = attempt_count + 1,
                    last_error = ?,
                    next_attempt_at = ?
                WHERE id = ?
                """,
                arguments: [
                    error,
                    nextAttemptAt.map(SQLiteDateCoding.string(from:)),
                    operationId.uuidString
                ]
            )
        }
    }

    /// Clears error fields so a row is pending again without changing operation id/order.
    func markOutboxPending(operationId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_outbox
                SET last_error = NULL,
                    next_attempt_at = NULL
                WHERE id = ?
                """,
                arguments: [operationId.uuidString]
            )
        }
    }

    /// Allows immediate retry after reconnect without changing operation identity/order.
    func clearOutboxBackoff() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_outbox SET next_attempt_at = NULL")
        }
    }

    /// Creates/upserts a folder and enqueues a create operation in one transaction.
    func persistDrawingFolderCreate(
        _ folder: DrawingFolder,
        operationId: UUID = UUID()
    ) throws {
        try dbQueue.write { db in
            try Self.upsertFolders([folder], db: db)
            try Self.insertOutboxEntry(
                operationId: operationId,
                entityType: .drawingFolder,
                entityId: folder.id,
                operation: .create,
                payloadJSON: try Self.folderPayloadJSON(folder),
                db: db
            )
        }
    }

    /// Upserts renamed folder fields and enqueues an update operation in one transaction.
    func persistDrawingFolderRename(
        _ folder: DrawingFolder,
        operationId: UUID = UUID()
    ) throws {
        try dbQueue.write { db in
            try Self.upsertFolders([folder], db: db)
            try Self.insertOutboxEntry(
                operationId: operationId,
                entityType: .drawingFolder,
                entityId: folder.id,
                operation: .update,
                payloadJSON: try Self.folderPayloadJSON(folder),
                db: db
            )
        }
    }

    /// Deletes a folder and enqueues a delete operation in one transaction.
    func persistDrawingFolderDelete(
        _ folder: DrawingFolder,
        operationId: UUID = UUID()
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM drawing_folders WHERE id = ?",
                arguments: [folder.id.uuidString]
            )
            try Self.insertOutboxEntry(
                operationId: operationId,
                entityType: .drawingFolder,
                entityId: folder.id,
                operation: .delete,
                payloadJSON: try Self.folderPayloadJSON(folder),
                db: db
            )
        }
    }

    /// Enqueues drawing metadata create after a confirmed PDF upload.
    /// Idempotent: skips when already marked pushed or an outbox create is pending.
    @discardableResult
    func enqueueDrawingMetadataSyncIfNeeded(
        drawingId: UUID,
        operationId: UUID = UUID()
    ) throws -> Bool {
        try dbQueue.write { db in
            if try Self.syncStateValue(
                key: Self.drawingMetadataSyncKey(drawingId),
                db: db
            ) != nil {
                return false
            }
            if try Self.hasOutboxEntry(
                entityType: .drawing,
                entityId: drawingId,
                operation: .create,
                db: db
            ) {
                return false
            }

            guard let transfer = try Self.fetchDrawingUpload(drawingId: drawingId, db: db),
                  transfer.status == .completed,
                  let remotePath = transfer.remotePath,
                  let revisionId = Self.revisionId(fromRemotePath: remotePath)
            else {
                return false
            }

            guard let drawing = try Self.fetchDrawingRow(id: drawingId, db: db) else {
                return false
            }

            let payload = DrawingMetadataPayload(
                id: drawing.id,
                projectId: drawing.projectId,
                folderId: drawing.folderId,
                name: drawing.name,
                fileName: drawing.fileName,
                pageCount: drawing.pageCount,
                createdDate: drawing.createdDate,
                revisionLabel: drawing.revision,
                discipline: drawing.discipline,
                location: drawing.location,
                drawingDate: drawing.drawingDate,
                revisionId: revisionId,
                storagePath: remotePath
            )
            try Self.insertOutboxEntry(
                operationId: operationId,
                entityType: .drawing,
                entityId: drawing.id,
                operation: .create,
                payloadJSON: try Self.drawingPayloadJSON(payload),
                db: db
            )
            return true
        }
    }

    /// For completed PDF uploads in a project, enqueue metadata sync when not yet pushed.
    /// Does not enqueue uploads for drawings that never had a transfer (legacy stay local).
    func reconcileDrawingMetadataOutbox(projectId: UUID) throws {
        let completed = try fetchCompletedDrawingPDFUploads(projectId: projectId)
        for transfer in completed {
            _ = try enqueueDrawingMetadataSyncIfNeeded(drawingId: transfer.entityId)
        }
    }

    /// Records that drawing metadata reached Postgres (survives outbox row deletion).
    func markDrawingMetadataPushed(drawingId: UUID, revisionId: UUID, now: Date = Date()) throws {
        try dbQueue.write { db in
            try Self.upsertSyncState(
                key: Self.drawingMetadataSyncKey(drawingId),
                value: revisionId.uuidString,
                now: now,
                db: db
            )
        }
    }

    /// Creates/upserts an area and enqueues a create operation in one transaction.
    /// Idempotent: skips outbox when already marked pushed or a create is pending.
    func persistAreaCreate(
        _ area: Area,
        operationId: UUID = UUID()
    ) throws {
        try dbQueue.write { db in
            try Self.upsertAreas([area], db: db)

            if try Self.syncStateValue(
                key: Self.areaCreateSyncKey(area.id),
                db: db
            ) != nil {
                return
            }
            if try Self.hasOutboxEntry(
                entityType: .area,
                entityId: area.id,
                operation: .create,
                db: db
            ) {
                return
            }

            try Self.insertOutboxEntry(
                operationId: operationId,
                entityType: .area,
                entityId: area.id,
                operation: .create,
                payloadJSON: try Self.areaPayloadJSON(area),
                db: db
            )
        }
    }

    /// Records that an area create reached Postgres (survives outbox row deletion).
    func markAreaCreatePushed(areaId: UUID, now: Date = Date()) throws {
        try dbQueue.write { db in
            try Self.upsertSyncState(
                key: Self.areaCreateSyncKey(areaId),
                value: "1",
                now: now,
                db: db
            )
        }
    }

    /// Revision UUID recorded when drawing metadata was pushed/pulled, if any.
    func syncedDrawingRevisionId(drawingId: UUID) throws -> UUID? {
        try dbQueue.read { db in
            guard let raw = try Self.syncStateValue(
                key: Self.drawingMetadataSyncKey(drawingId),
                db: db
            ) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
    }

    // MARK: - Internals

    static func drawingMetadataSyncKey(_ drawingId: UUID) -> String {
        "drawing_metadata_pushed:\(drawingId.uuidString)"
    }

    static func areaCreateSyncKey(_ areaId: UUID) -> String {
        "area_create_pushed:\(areaId.uuidString)"
    }

    static func revisionId(fromRemotePath path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[1].hasSuffix(".pdf") else { return nil }
        let idPart = String(parts[1].dropLast(4))
        return UUID(uuidString: idPart)
    }

    static func drawingPayloadJSON(_ payload: DrawingMetadataPayload) throws -> String {
        var object: [String: Any] = [
            "id": payload.id.uuidString,
            "projectId": payload.projectId.uuidString,
            "name": payload.name,
            "fileName": payload.fileName,
            "pageCount": payload.pageCount,
            "createdDate": SQLiteDateCoding.string(from: payload.createdDate),
            "revisionId": payload.revisionId.uuidString,
            "storagePath": payload.storagePath
        ]
        if let folderId = payload.folderId {
            object["folderId"] = folderId.uuidString
        } else {
            object["folderId"] = NSNull()
        }
        object["revision"] = payload.revisionLabel.map { $0 as Any } ?? NSNull()
        object["discipline"] = payload.discipline.map { $0 as Any } ?? NSNull()
        object["location"] = payload.location.map { $0 as Any } ?? NSNull()
        if let drawingDate = payload.drawingDate {
            object["drawingDate"] = SQLiteDateCoding.string(from: drawingDate)
        } else {
            object["drawingDate"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncOutboxStoreError.payloadEncodingFailed
        }
        return text
    }

    private static func hasOutboxEntry(
        entityType: SyncOutboxEntityType,
        entityId: UUID,
        operation: SyncOutboxOperation,
        db: Database
    ) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM sync_outbox
            WHERE entity_type = ? AND entity_id = ? AND operation = ?
            """,
            arguments: [entityType.rawValue, entityId.uuidString, operation.rawValue]
        ) ?? 0
        return count > 0
    }

    private static func syncStateValue(key: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM sync_state WHERE key = ?",
            arguments: [key]
        )
    }

    static func upsertSyncState(
        key: String,
        value: String,
        now: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_state (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              value = excluded.value,
              updated_at = excluded.updated_at
            """,
            arguments: [key, value, SQLiteDateCoding.string(from: now)]
        )
    }

    static func insertOutboxEntry(
        operationId: UUID,
        entityType: SyncOutboxEntityType,
        entityId: UUID,
        operation: SyncOutboxOperation,
        payloadJSON: String?,
        createdAt: Date = Date(),
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_outbox
              (id, entity_type, entity_id, operation, payload_json,
               created_at, attempt_count, last_error, next_attempt_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL)
            """,
            arguments: [
                operationId.uuidString,
                entityType.rawValue,
                entityId.uuidString,
                operation.rawValue,
                payloadJSON,
                SQLiteDateCoding.string(from: createdAt)
            ]
        )
    }

    private static func folderPayloadJSON(_ folder: DrawingFolder) throws -> String {
        var payload: [String: Any] = [
            "id": folder.id.uuidString,
            "projectId": folder.projectId.uuidString,
            "name": folder.name,
            "sortOrder": folder.sortOrder,
            "createdDate": SQLiteDateCoding.string(from: folder.createdDate)
        ]
        if let parent = folder.parentFolderId {
            payload["parentFolderId"] = parent.uuidString
        } else {
            payload["parentFolderId"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncOutboxStoreError.payloadEncodingFailed
        }
        return text
    }

    static func areaPayloadJSON(_ area: Area) throws -> String {
        let vertices = area.vertices.map { ["x": $0.x, "y": $0.y] }
        let payload: [String: Any] = [
            "id": area.id.uuidString,
            "projectId": area.projectId.uuidString,
            "drawingId": area.drawingId.uuidString,
            "pageIndex": area.pageIndex,
            "name": area.name,
            "vertices": vertices,
            "color": area.color,
            "opacity": area.opacity,
            "isVisible": area.isVisible,
            "createdDate": SQLiteDateCoding.string(from: area.createdDate),
            "updatedDate": SQLiteDateCoding.string(from: area.updatedDate)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncOutboxStoreError.payloadEncodingFailed
        }
        return text
    }

    private static func outboxEntry(from row: Row) throws -> SyncOutboxEntry {
        guard let id = UUID(uuidString: row["id"]),
              let entityId = UUID(uuidString: row["entity_id"])
        else {
            throw SyncOutboxStoreError.invalidRow
        }
        let entityRaw: String = row["entity_type"]
        let opRaw: String = row["operation"]
        guard let entityType = SyncOutboxEntityType(rawValue: entityRaw),
              let operation = SyncOutboxOperation(rawValue: opRaw)
        else {
            throw SyncOutboxStoreError.invalidRow
        }
        let createdRaw: String = row["created_at"]
        let nextRaw: String? = row["next_attempt_at"]
        return SyncOutboxEntry(
            id: id,
            entityType: entityType,
            entityId: entityId,
            operation: operation,
            payloadJSON: row["payload_json"],
            createdAt: SQLiteDateCoding.date(from: createdRaw) ?? Date(),
            attemptCount: row["attempt_count"],
            lastError: row["last_error"],
            nextAttemptAt: nextRaw.flatMap(SQLiteDateCoding.date(from:))
        )
    }
}

enum SyncOutboxStoreError: LocalizedError {
    case invalidRow
    case payloadEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidRow:
            return "Invalid sync_outbox row"
        case .payloadEncodingFailed:
            return "Failed to encode outbox payload JSON"
        }
    }
}
