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

/// Entity kinds that may appear in the outbox. Folder sync is first.
enum SyncOutboxEntityType: String, Equatable {
    case drawingFolder = "drawing_folder"
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

    // MARK: - Internals

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
