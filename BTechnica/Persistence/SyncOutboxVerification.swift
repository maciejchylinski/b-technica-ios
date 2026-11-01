import Foundation
import GRDB

/// Targeted check: folder create/rename/delete enqueue outbox ops; reopen preserves order;
/// bulk persist / reopen does not duplicate operations.
enum SyncOutboxVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
    }

    static func run() -> Result {
        do {
            return try runThrowing()
        } catch {
            return Result(passed: false, message: "Threw: \(error.localizedDescription)")
        }
    }

    private static func runThrowing() throws -> Result {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-sync-outbox-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let folderId = UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333")!
        let createOp = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let renameOp = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let deleteOp = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

        let project = Project(
            id: projectId,
            name: "Outbox Check",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Plans",
            sortOrder: 0,
            createdDate: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.ensureProject(project)

        try db.persistDrawingFolderCreate(folder, operationId: createOp)
        folder.name = "Plans Renamed"
        try db.persistDrawingFolderRename(folder, operationId: renameOp)
        try db.persistDrawingFolderDelete(folder, operationId: deleteOp)

        // Bulk workspace write must not invent outbox rows (JSON recovery / reopen path).
        try db.persistProjectWorkspace(
            project: project,
            folders: [],
            drawings: [],
            areas: [],
            issues: []
        )

        let reopened = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        let queued = try reopened.fetchAllOutboxEntries()

        guard queued.count == 3 else {
            return Result(
                passed: false,
                message: "Expected 3 outbox ops after reopen, got \(queued.count)"
            )
        }
        guard queued.map(\.id) == [createOp, renameOp, deleteOp] else {
            return Result(passed: false, message: "Outbox operation UUIDs/order not preserved")
        }
        guard queued.map(\.operation) == [.create, .update, .delete] else {
            return Result(passed: false, message: "Outbox operations mismatch: \(queued.map(\.operation.rawValue))")
        }
        guard queued.allSatisfy({ $0.entityType == .drawingFolder && $0.entityId == folderId }) else {
            return Result(passed: false, message: "Outbox entity type/id mismatch")
        }
        guard queued.allSatisfy({ $0.status == .pending && $0.attemptCount == 0 }) else {
            return Result(passed: false, message: "Fresh outbox rows should be pending")
        }

        // Error + retry bookkeeping without changing operation identity.
        try reopened.markOutboxError(
            operationId: createOp,
            error: "offline",
            nextAttemptAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let afterError = try reopened.fetchAllOutboxEntries()
        guard let errored = afterError.first(where: { $0.id == createOp }),
              errored.status == .error,
              errored.attemptCount == 1,
              errored.lastError == "offline"
        else {
            return Result(passed: false, message: "markOutboxError did not set error state")
        }

        try reopened.markOutboxPending(operationId: createOp)
        guard try reopened.fetchAllOutboxEntries().first(where: { $0.id == createOp })?.status == .pending
        else {
            return Result(passed: false, message: "markOutboxPending failed")
        }

        try reopened.markOutboxSent(operationId: createOp)
        let afterSent = try reopened.fetchAllOutboxEntries()
        guard afterSent.map(\.id) == [renameOp, deleteOp] else {
            return Result(passed: false, message: "markOutboxSent should remove only that op")
        }

        // Re-open again: remaining ops stable; no duplicates from empty bulk write.
        let again = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try again.replaceFoldersAndDrawings(project: project, folders: [], drawings: [])
        let finalOps = try again.fetchAllOutboxEntries()
        guard finalOps.map(\.id) == [renameOp, deleteOp] else {
            return Result(
                passed: false,
                message: "Bulk persist/reopen duplicated or lost outbox ops"
            )
        }

        return Result(
            passed: true,
            message: "Folder create/rename/delete outbox ops preserved in order across reopen."
        )
    }
}
