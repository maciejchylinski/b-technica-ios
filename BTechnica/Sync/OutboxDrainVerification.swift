// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB

/// Regression checks for outbox draining (`SyncOutboxPushService.pushPending`) with fake remotes
/// on an isolated temp database. Launch argument `-BTVerifyOutboxDrain`; exit code 0 = passed.
///
/// Scenario 1 — isolation. Queue (oldest first): folder create for inactive project A, drawing
/// create for active project B without a confirmed PDF, folder create for B. Draining B must
/// push B's folder, leave A's op untouched, and keep the drawing op queued with an error.
///
/// Scenario 2 — dependencies. Queue for B: folder F, drawing D in F (PDF upload reset to
/// pending), area on D (dependent), folder G (independent).
///   drain 1: F and G pushed; D and the area stay queued with errors (area never bypasses D).
///   drain 2: still blocked; nothing pushed twice; skipped rows persist, attempts increase.
///   upload confirmed, drain 3: D pushed, then the area; queue empty.
enum OutboxDrainVerification {
    struct Result {
        var passed: Bool
        var message: String
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifyOutboxDrain") else { return }
        let result = run()
        fputs("BT_OUTBOX_DRAIN_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
        try? "passed=\(result.passed)\n\(result.message)\n".write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("bt-outbox-drain-verify.txt"),
            atomically: true,
            encoding: .utf8
        )
        exit(result.passed ? 0 : 1)
    }

    static func run() -> Result {
        let box = ResultBox()
        Task { @MainActor in
            let coordinator = DrawingFolderSyncCoordinator.shared
            let previousBypass = coordinator.isTestBypassConfigured
            coordinator.isTestBypassConfigured = true
            defer { coordinator.isTestBypassConfigured = previousBypass }
            do {
                let first = try await isolationScenario()
                if first.passed {
                    box.value = try await dependencyScenario()
                } else {
                    box.value = first
                }
            } catch {
                box.value = Result(passed: false, message: "Threw: \(error.localizedDescription)")
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while box.value == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.value ?? Result(passed: false, message: "Outbox drain check timed out")
    }

    @MainActor
    private static func makeDatabase(_ label: String) throws -> (AppDatabase, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("btechnica-outbox-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.open(userId: UUID(), at: root.appendingPathComponent("btechnica.sqlite"), rootURL: root)
        return (db, root)
    }

    /// Distinct `created_at` values so FIFO order is deterministic.
    private static func tick() async throws {
        try await Task.sleep(nanoseconds: 1_100_000_000)
    }

    // MARK: - Scenario 1

    @MainActor
    private static func isolationScenario() async throws -> Result {
        let (db, root) = try makeDatabase("isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectA = Project(name: "A")
        let projectB = Project(name: "B")
        try db.ensureProject(projectA)
        try db.ensureProject(projectB)

        let folderA = DrawingFolder(projectId: projectA.id, parentFolderId: nil, name: "A root", sortOrder: 0)
        try db.persistDrawingFolderCreate(folderA)
        try await tick()
        let drawingOpId = UUID()
        let drawingId = UUID()
        let payload = DrawingMetadataPayload(
            id: drawingId, projectId: projectB.id, folderId: nil, name: "Unuploaded", fileName: "\(drawingId.uuidString).pdf",
            pageCount: 1, createdDate: Date(), revisionLabel: nil, discipline: nil, location: nil, drawingDate: nil,
            revisionId: UUID(), storagePath: "\(projectB.id.uuidString)/\(drawingId.uuidString).pdf"
        )
        try db.dbQueue.write { conn in
            try AppDatabase.insertOutboxEntry(
                operationId: drawingOpId, entityType: .drawing, entityId: drawingId, operation: .create,
                payloadJSON: try AppDatabase.drawingPayloadJSON(payload), db: conn
            )
        }
        try await tick()
        let folderB = DrawingFolder(projectId: projectB.id, parentFolderId: nil, name: "B root", sortOrder: 0)
        try db.persistDrawingFolderCreate(folderB)

        let log = EventLog()
        let folders = RecordingDrawingFolderRemote()
        await drain(db, projectB.id, folders, log)

        let remaining = try db.fetchAllOutboxEntries()
        guard folders.events.contains(.ensureCreated(folderB.id)), !remaining.contains(where: { $0.entityId == folderB.id }) else {
            return Result(passed: false, message: "S1: project B folder was not pushed (head-of-line blocked); events=\(folders.events)")
        }
        guard !folders.events.contains(.ensureCreated(folderA.id)),
              remaining.contains(where: { $0.entityId == folderA.id && $0.lastError == nil && $0.attemptCount == 0 }) else {
            return Result(passed: false, message: "S1: project A op was pushed or modified while B was active")
        }
        guard remaining.first(where: { $0.id == drawingOpId })?.lastError != nil, log.entries.isEmpty else {
            return Result(passed: false, message: "S1: unuploaded drawing op should stay queued with an error")
        }
        return Result(passed: true, message: "S1 ok")
    }

    // MARK: - Scenario 2

    @MainActor
    private static func dependencyScenario() async throws -> Result {
        let (db, root) = try makeDatabase("dependency")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "B")
        try db.ensureProject(project)

        let folderF = DrawingFolder(projectId: project.id, parentFolderId: nil, name: "F", sortOrder: 0)
        try db.persistDrawingFolderCreate(folderF)
        let drawing = Drawing(projectId: project.id, folderId: folderF.id, name: "D", fileName: "d.pdf", pageCount: 1)
        try db.persistProjectWorkspace(project: project, folders: [folderF], drawings: [drawing], areas: [], issues: [])
        try await tick()

        // Upload completed once (so the drawing create op exists), then reset to pending,
        // e.g. an interrupted re-upload: the drawing create must wait for it.
        _ = try db.enqueueDrawingPDFUpload(drawingId: drawing.id, projectId: project.id, fileName: drawing.fileName, bytesTotal: nil)
        guard let transfer = try db.fetchDrawingPDFUpload(drawingId: drawing.id) else {
            return Result(passed: false, message: "S2 setup: no upload transfer")
        }
        try db.markFileTransferCompleted(id: transfer.id, bytesDone: nil)
        guard try db.enqueueDrawingMetadataSyncIfNeeded(drawingId: drawing.id) else {
            return Result(passed: false, message: "S2 setup: drawing create op not enqueued")
        }
        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE file_transfers SET status = 'pending' WHERE id = ?", arguments: [transfer.id.uuidString])
        }
        try await tick()
        let area = Area(projectId: project.id, drawingId: drawing.id, pageIndex: 0, name: "Zone",
                        vertices: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 0, y: 1)])
        try db.persistAreaCreate(area)
        try await tick()
        let folderG = DrawingFolder(projectId: project.id, parentFolderId: nil, name: "G", sortOrder: 1)
        try db.persistDrawingFolderCreate(folderG)

        let log = EventLog()
        let folders = RecordingDrawingFolderRemote()

        // Drain 1: blocked drawing; dependent area must not bypass it; independent ops flow.
        await drain(db, project.id, folders, log)
        var remaining = try db.fetchAllOutboxEntries()
        guard folders.events.contains(.ensureCreated(folderF.id)), folders.events.contains(.ensureCreated(folderG.id)) else {
            return Result(passed: false, message: "S2 drain 1: independent folders not pushed; events=\(folders.events)")
        }
        guard log.entries.isEmpty else {
            return Result(passed: false, message: "S2 drain 1: drawing or dependent area pushed before PDF upload: \(log.entries)")
        }
        let drawingAttempts1 = remaining.first { $0.entityId == drawing.id }?.attemptCount ?? -1
        guard drawingAttempts1 == 1, remaining.contains(where: { $0.entityId == area.id && $0.lastError != nil }),
              remaining.count == 2 else {
            return Result(passed: false, message: "S2 drain 1: expected drawing + area queued with errors, got \(remaining.map(\.entityType))")
        }

        // Drain 2: still blocked — no duplicate pushes, skipped rows persist.
        let folderEventsBefore = folders.events.count
        await drain(db, project.id, folders, log)
        remaining = try db.fetchAllOutboxEntries()
        guard folders.events.count == folderEventsBefore, log.entries.isEmpty, remaining.count == 2,
              remaining.first(where: { $0.entityId == drawing.id })?.attemptCount == 2 else {
            return Result(passed: false, message: "S2 drain 2: duplicate push or lost queued op; events=\(folders.events) log=\(log.entries)")
        }

        // Upload confirmed → drain 3 pushes the drawing, then the dependent area.
        try db.markFileTransferCompleted(id: transfer.id, bytesDone: nil)
        await drain(db, project.id, folders, log)
        remaining = try db.fetchAllOutboxEntries()
        guard log.entries == ["drawing:\(drawing.id.uuidString)", "area:\(area.id.uuidString)"], remaining.isEmpty else {
            return Result(passed: false, message: "S2 drain 3: expected drawing then area, got \(log.entries); remaining=\(remaining.count)")
        }
        return Result(passed: true, message: "S1 isolation ok; S2 dependency ordering ok (blocked drawing, deferred area, independent folders, no duplicates)")
    }

    @MainActor
    private static func drain(_ db: AppDatabase, _ projectId: UUID, _ folders: RecordingDrawingFolderRemote, _ log: EventLog) async {
        await SyncOutboxPushService.shared.pushPending(
            userId: db.userId,
            projectId: projectId,
            remote: folders,
            drawingRemote: RecordingDrawingRemote(log: log),
            areaRemote: RecordingAreaRemote(log: log),
            database: db
        )
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result?
    }
}

/// Shared push log so cross-remote ordering (drawing before area) is observable.
private final class EventLog: @unchecked Sendable {
    var entries: [String] = []
}

private struct RecordingDrawingRemote: DrawingRemoteStore {
    let log: EventLog

    func ensureCreated(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult {
        log.entries.append("drawing:\(payload.id.uuidString)")
        return .created
    }

    func fetchRevisionPages(revisionId: UUID) async throws -> [RemoteDrawingPage] {
        [RemoteDrawingPage(id: UUID(), revisionId: revisionId, pageIndex: 0)]
    }

    func fetchProjectDrawings(projectId: UUID) async throws -> [RemoteDrawing] {
        []
    }
}

private struct RecordingAreaRemote: AreaRemoteStore {
    let log: EventLog

    func ensureCreated(_ payload: AreaCreatePayload) async throws -> AreaRemoteCreateResult {
        log.entries.append("area:\(payload.id.uuidString)")
        return .created
    }
}
#endif
