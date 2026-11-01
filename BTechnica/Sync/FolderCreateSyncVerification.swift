import Foundation

/// Local (fake-remote) check for folder create/rename/delete outbox drain + idempotency.
enum FolderCreateSyncVerification {
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
            .appendingPathComponent("btechnica-folder-create-sync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let folderId = UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333")!
        let createOp = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let renameOp = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let deleteOp = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let retryOp = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!

        let project = Project(
            id: projectId,
            name: "Sync Check",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Offline Root",
            sortOrder: 0,
            createdDate: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.ensureProject(project)
        try db.persistDrawingFolderCreate(folder, operationId: createOp)

        let remote = FakeDrawingFolderRemote()
        remote.failNextMutations = 1

        let failed = try drain(database: db, projectId: projectId, remote: remote)
        guard failed.sent == 0, failed.stoppedOnError, remote.activeRows.isEmpty else {
            return Result(passed: false, message: "Expected network failure to leave create pending")
        }

        try db.clearOutboxBackoff()
        let created = try drain(database: db, projectId: projectId, remote: remote)
        guard created.sent == 1, remote.activeRows[folderId]?.name == "Offline Root" else {
            return Result(passed: false, message: "Create did not land once on reconnect")
        }

        // Idempotent create retry with consistency check.
        try db.persistDrawingFolderCreate(folder, operationId: retryOp)
        let retry = try drain(database: db, projectId: projectId, remote: remote)
        guard retry.sent == 1, remote.insertAttempts == 1, remote.alreadyPresentCount == 1 else {
            return Result(passed: false, message: "Create retry not idempotent")
        }

        folder.name = "Renamed Root"
        try db.persistDrawingFolderRename(folder, operationId: renameOp)
        let renamed = try drain(database: db, projectId: projectId, remote: remote)
        guard renamed.sent == 1, remote.activeRows[folderId]?.name == "Renamed Root" else {
            return Result(passed: false, message: "Rename did not apply")
        }

        try db.persistDrawingFolderDelete(folder, operationId: deleteOp)
        let deleted = try drain(database: db, projectId: projectId, remote: remote)
        guard deleted.sent == 1,
              remote.activeRows[folderId] == nil,
              try db.fetchAllOutboxEntries().isEmpty
        else {
            return Result(passed: false, message: "Delete did not clear outbox/remote")
        }

        // Idempotent delete retry.
        let deleteRetryOp = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        try db.persistDrawingFolderDelete(folder, operationId: deleteRetryOp)
        let deleteRetry = try drain(database: db, projectId: projectId, remote: remote)
        guard deleteRetry.sent == 1, remote.alreadyDeletedCount == 1 else {
            return Result(passed: false, message: "Delete retry not idempotent")
        }

        return Result(
            passed: true,
            message: "Create/rename/delete drained with idempotent retries on fake remote."
        )
    }

    private struct DrainResult {
        var sent: Int
        var stoppedOnError: Bool
    }

    private static func drain(
        database: AppDatabase,
        projectId: UUID,
        remote: FakeDrawingFolderRemote
    ) throws -> DrainResult {
        var sent = 0
        var stoppedOnError = false
        for entry in try database.fetchOutboxEntries() {
            guard entry.entityType == .drawingFolder else { break }
            let folder: DrawingFolder
            do {
                folder = try SyncOutboxPushService.folder(from: entry)
            } catch {
                try database.markOutboxError(
                    operationId: entry.id,
                    error: error.localizedDescription,
                    nextAttemptAt: Date().addingTimeInterval(2)
                )
                stoppedOnError = true
                break
            }
            guard folder.projectId == projectId else { break }

            do {
                switch entry.operation {
                case .create:
                    _ = try remote.ensureCreatedSync(folder)
                case .update:
                    _ = try remote.ensureRenamedSync(folder)
                case .delete:
                    _ = try remote.ensureDeletedSync(folder)
                }
                try database.markOutboxSent(operationId: entry.id)
                sent += 1
            } catch {
                try database.markOutboxError(
                    operationId: entry.id,
                    error: error.localizedDescription,
                    nextAttemptAt: Date().addingTimeInterval(2)
                )
                stoppedOnError = true
                break
            }
        }
        return DrainResult(sent: sent, stoppedOnError: stoppedOnError)
    }
}

/// In-memory stand-in for Supabase `drawing_folders` create/rename/soft-delete.
final class FakeDrawingFolderRemote: DrawingFolderRemoteStore, @unchecked Sendable {
    private(set) var rows: [UUID: DrawingFolder] = [:]
    private(set) var deletedAt: [UUID: Date] = [:]
    private(set) var insertAttempts = 0
    private(set) var alreadyPresentCount = 0
    private(set) var alreadyDeletedCount = 0
    var failNextMutations = 0

    var activeRows: [UUID: DrawingFolder] {
        rows.filter { deletedAt[$0.key] == nil }
    }

    func ensureCreated(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteCreateResult {
        try ensureCreatedSync(folder)
    }

    func ensureRenamed(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteRenameResult {
        try ensureRenamedSync(folder)
    }

    func ensureDeleted(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteDeleteResult {
        try ensureDeletedSync(folder)
    }

    func ensureCreatedSync(_ folder: DrawingFolder) throws -> DrawingFolderRemoteCreateResult {
        try failIfRequested()
        if let existing = activeRows[folder.id] {
            guard existing.projectId == folder.projectId,
                  existing.parentFolderId == folder.parentFolderId,
                  existing.name.lowercased() == folder.name.lowercased(),
                  existing.sortOrder == folder.sortOrder
            else {
                throw DrawingFolderRemoteError.conflict("create consistency mismatch")
            }
            alreadyPresentCount += 1
            return .alreadyPresent
        }
        if siblingClash(folder) {
            throw DrawingFolderRemoteError.conflict("sibling name conflict")
        }
        insertAttempts += 1
        rows[folder.id] = folder
        deletedAt.removeValue(forKey: folder.id)
        return .created
    }

    func ensureRenamedSync(_ folder: DrawingFolder) throws -> DrawingFolderRemoteRenameResult {
        try failIfRequested()
        guard let existing = activeRows[folder.id] else {
            throw DrawingFolderRemoteError.conflict("missing for rename")
        }
        guard existing.projectId == folder.projectId else {
            throw DrawingFolderRemoteError.conflict("project mismatch")
        }
        if existing.name == folder.name {
            return .alreadyApplied
        }
        var renamed = folder
        renamed.parentFolderId = existing.parentFolderId
        renamed.sortOrder = existing.sortOrder
        renamed.createdDate = existing.createdDate
        if siblingClash(renamed, excluding: folder.id) {
            throw DrawingFolderRemoteError.conflict("sibling name conflict")
        }
        rows[folder.id] = renamed
        return .updated
    }

    func ensureDeletedSync(_ folder: DrawingFolder) throws -> DrawingFolderRemoteDeleteResult {
        try failIfRequested()
        guard let existing = rows[folder.id] else {
            alreadyDeletedCount += 1
            return .alreadyDeleted
        }
        guard existing.projectId == folder.projectId else {
            throw DrawingFolderRemoteError.conflict("project mismatch")
        }
        if deletedAt[folder.id] != nil {
            alreadyDeletedCount += 1
            return .alreadyDeleted
        }
        deletedAt[folder.id] = Date()
        return .deleted
    }

    private func failIfRequested() throws {
        if failNextMutations > 0 {
            failNextMutations -= 1
            throw URLError(.notConnectedToInternet)
        }
    }

    private func siblingClash(_ folder: DrawingFolder, excluding: UUID? = nil) -> Bool {
        activeRows.values.contains {
            $0.id != (excluding ?? folder.id)
                && $0.projectId == folder.projectId
                && $0.parentFolderId == folder.parentFolderId
                && $0.name.lowercased() == folder.name.lowercased()
        }
    }
}
