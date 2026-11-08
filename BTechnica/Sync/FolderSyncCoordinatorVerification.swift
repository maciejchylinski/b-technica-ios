// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation

/// Focused check: coordinator push→pull order, pending protection, protected tombstones, cancel.
enum FolderSyncCoordinatorVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
    }

    static func run() -> Result {
        let box = ResultBox()
        Task { @MainActor in
            do {
                box.value = try await runThrowing()
            } catch {
                box.value = Result(passed: false, message: "Threw: \(error.localizedDescription)")
            }
        }
        // App init runs on the main thread; pump the run loop so @MainActor work can finish.
        let deadline = Date().addingTimeInterval(30)
        while box.value == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.value ?? Result(passed: false, message: "Coordinator check timed out")
    }

    @MainActor
    private static func runThrowing() async throws -> Result {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-folder-sync-coord-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")!
        let projectId = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let folderId = UUID(uuidString: "ABCDEF00-1111-2222-3333-444444444444")!
        let protectedId = UUID(uuidString: "ABCDEF00-1111-2222-3333-555555555555")!
        let createOp = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(Project(id: projectId, name: "Coord", createdDate: Date()))

        let folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Coord Root",
            sortOrder: 0,
            createdDate: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try db.persistDrawingFolderCreate(folder, operationId: createOp)

        // Protected folder: local drawing must block remote tombstone removal.
        let protected = DrawingFolder(
            id: protectedId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Protected",
            sortOrder: 1,
            createdDate: Date(timeIntervalSince1970: 1_700_000_201)
        )
        try db.applyRemoteDrawingFolderPull(
            projectId: projectId,
            remoteFolders: [
                RemoteDrawingFolder(
                    id: protected.id,
                    projectId: projectId,
                    parentFolderId: nil,
                    name: protected.name,
                    sortOrder: protected.sortOrder,
                    createdAt: protected.createdDate,
                    deletedAt: nil
                )
            ]
        )
        try insertDrawingStub(db: db, projectId: projectId, folderId: protectedId)

        let remote = RecordingDrawingFolderRemote()
        remote.seedActive(folder)
        remote.seedTombstone(protected)

        let coordinator = DrawingFolderSyncCoordinator.shared
        coordinator.isTestBypassConfigured = true
        defer {
            coordinator.isTestBypassConfigured = false
            coordinator.cancel()
        }

        let result = await coordinator.syncNow(
            userId: userId,
            projectId: projectId,
            remote: remote,
            drawingRemote: EmptyDrawingRemoteStore(),
            database: db
        )
        guard let result, let pull = result.pull else {
            return Result(passed: false, message: "Coordinator syncNow returned nil")
        }

        guard remote.events == [.ensureCreated(folderId), .fetchProjectFolders(projectId)] else {
            return Result(
                passed: false,
                message: "Expected push-then-pull order, got \(remote.events)"
            )
        }
        guard try db.fetchAllOutboxEntries().isEmpty else {
            return Result(passed: false, message: "Outbox not drained by coordinator push")
        }
        let local = try db.fetchDrawingFolders(projectId: projectId)
        guard local.contains(where: { $0.id == folderId }) else {
            return Result(passed: false, message: "Pushed folder missing after pull")
        }
        guard local.contains(where: { $0.id == protectedId }) else {
            return Result(passed: false, message: "Protected tombstone removed a folder with drawings")
        }
        guard pull.skippedProtected >= 1 else {
            return Result(passed: false, message: "Expected skippedProtected for folder with drawings")
        }

        // Failed push leaves pending op; pull must not overwrite.
        let pendingId = UUID(uuidString: "ABCDEF00-1111-2222-3333-666666666666")!
        let pending = DrawingFolder(
            id: pendingId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Pending Local",
            sortOrder: 2,
            createdDate: Date()
        )
        try db.persistDrawingFolderCreate(pending, operationId: UUID())
        remote.failNextMutations = 1
        remote.seedActive(
            DrawingFolder(
                id: pendingId,
                projectId: projectId,
                parentFolderId: nil,
                name: "Remote Conflict",
                sortOrder: 2,
                createdDate: Date()
            )
        )
        remote.resetEvents()

        _ = await coordinator.syncNow(
            userId: userId,
            projectId: projectId,
            remote: remote,
            drawingRemote: EmptyDrawingRemoteStore(),
            database: db
        )
        let afterFail = try db.fetchDrawingFolders(projectId: projectId)
        guard afterFail.contains(where: { $0.id == pendingId && $0.name == "Pending Local" }) else {
            return Result(passed: false, message: "Failed push allowed remote overwrite of pending folder")
        }
        guard try db.fetchAllOutboxEntries().contains(where: { $0.entityId == pendingId }) else {
            return Result(passed: false, message: "Pending outbox should remain after push failure")
        }

        // Cancel clears workspace binding so a later schedule is not stale-bound.
        coordinator.cancel()
        let afterCancel = await coordinator.syncNow(
            userId: userId,
            projectId: projectId,
            remote: remote,
            drawingRemote: EmptyDrawingRemoteStore(),
            database: db
        )
        guard afterCancel != nil else {
            return Result(passed: false, message: "syncNow after cancel should still run when rebound")
        }

        return Result(
            passed: true,
            message: "Coordinator push→pull, pending protection, protected tombstone, cancel ok"
        )
    }

    private static func insertDrawingStub(db: AppDatabase, projectId: UUID, folderId: UUID) throws {
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO drawings
                  (id, project_id, folder_id, name, file_name, page_count, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    projectId.uuidString,
                    folderId.uuidString,
                    "Stub Drawing",
                    "stub.pdf",
                    1,
                    SQLiteDateCoding.string(from: Date())
                ]
            )
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result?
    }
}

/// No-op drawing remote for folder-only coordinator checks.
struct EmptyDrawingRemoteStore: DrawingRemoteStore {
    func ensureCreated(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult {
        .alreadyPresent
    }

    func fetchRevisionPages(revisionId: UUID) async throws -> [RemoteDrawingPage] {
        []
    }

    func fetchProjectDrawings(projectId: UUID) async throws -> [RemoteDrawing] {
        []
    }
}

/// Records call order for coordinator sequencing checks.
final class RecordingDrawingFolderRemote: DrawingFolderRemoteStore, @unchecked Sendable {
    enum Event: Equatable {
        case ensureCreated(UUID)
        case ensureRenamed(UUID)
        case ensureDeleted(UUID)
        case fetchProjectFolders(UUID)
    }

    private(set) var events: [Event] = []
    private var rows: [UUID: RemoteDrawingFolder] = [:]
    var failNextMutations = 0

    func resetEvents() {
        events = []
    }

    func seedActive(_ folder: DrawingFolder) {
        rows[folder.id] = RemoteDrawingFolder(
            id: folder.id,
            projectId: folder.projectId,
            parentFolderId: folder.parentFolderId,
            name: folder.name,
            sortOrder: folder.sortOrder,
            createdAt: folder.createdDate,
            deletedAt: nil
        )
    }

    func seedTombstone(_ folder: DrawingFolder) {
        rows[folder.id] = RemoteDrawingFolder(
            id: folder.id,
            projectId: folder.projectId,
            parentFolderId: folder.parentFolderId,
            name: folder.name,
            sortOrder: folder.sortOrder,
            createdAt: folder.createdDate,
            deletedAt: Date()
        )
    }

    func ensureCreated(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteCreateResult {
        try failIfRequested()
        events.append(.ensureCreated(folder.id))
        if let existing = rows[folder.id], existing.deletedAt == nil {
            return .alreadyPresent
        }
        seedActive(folder)
        return .created
    }

    func ensureRenamed(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteRenameResult {
        try failIfRequested()
        events.append(.ensureRenamed(folder.id))
        seedActive(folder)
        return .updated
    }

    func ensureDeleted(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteDeleteResult {
        try failIfRequested()
        events.append(.ensureDeleted(folder.id))
        seedTombstone(folder)
        return .deleted
    }

    func fetchProjectFolders(projectId: UUID) async throws -> [RemoteDrawingFolder] {
        events.append(.fetchProjectFolders(projectId))
        return rows.values.filter { $0.projectId == projectId }
    }

    private func failIfRequested() throws {
        if failNextMutations > 0 {
            failNextMutations -= 1
            throw URLError(.notConnectedToInternet)
        }
    }
}
#endif
