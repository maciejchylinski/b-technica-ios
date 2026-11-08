// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB

/// Regression checks for incremental workspace persistence (`SQLiteWorkspaceBaseline` +
/// `persistProjectWorkspaceDelta`) and the grouped photo / calibration fetches.
/// Mirrors `AppStore.persist`: diff memory against the baseline, write the delta in one
/// transaction, advance the baseline only after success. Isolated temp database.
///
/// Run: launch argument `-BTVerifyWorkspaceDelta`; result in stderr (`BT_WORKSPACE_DELTA_VERIFY`)
/// and `tmp/bt-workspace-delta-verify.json`; exit code 0 = passed.
enum WorkspaceDeltaPersistenceVerification {
    struct Result {
        var passed: Bool
        var message: String
        var checks: [String]
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifyWorkspaceDelta") else { return }
        let result = run()
        let payload: [String: Any] = ["passed": result.passed, "message": result.message, "checks": result.checks]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bt-workspace-delta-verify.json")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            fputs("BT_WORKSPACE_DELTA_VERIFY \(text)\n", stderr)
        } else {
            fputs("BT_WORKSPACE_DELTA_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
        }
        exit(result.passed ? 0 : 1)
    }

    static func run() -> Result {
        var checks: [String] = []
        do {
            try runThrowing(checks: &checks)
            return Result(passed: true, message: "All workspace delta checks passed", checks: checks)
        } catch {
            return Result(passed: false, message: "\(error)", checks: checks)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ label: String, _ checks: inout [String]) throws {
        guard condition else { throw Failure(description: "FAILED: \(label)") }
        checks.append("ok: \(label)")
    }

    /// One `AppStore.persist` step: delta write, then advance the baseline.
    private struct Saver {
        let db: AppDatabase
        var baseline: SQLiteWorkspaceBaseline

        mutating func save(_ data: AppData) throws -> ProjectWorkspaceDelta {
            let delta = baseline.delta(to: data)
            if !delta.isEmpty || baseline.projectName != data.project.name {
                try db.persistProjectWorkspaceDelta(project: data.project, delta: delta)
            }
            baseline = SQLiteWorkspaceBaseline(data: data)
            return delta
        }
    }

    private static func count(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try db.dbQueue.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
    }

    // swiftlint:disable:next function_body_length
    private static func runThrowing(checks: inout [String]) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-workspace-delta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID()
        let db = try AppDatabase.open(userId: userId, at: root.appendingPathComponent("btechnica.sqlite"), rootURL: root)
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        // Project A (under test) and project B (must never be touched).
        let projectA = Project(name: "A", createdDate: t0)
        let projectB = Project(name: "B", createdDate: t0)
        func drawing(_ project: Project, _ name: String) -> Drawing {
            let id = UUID()
            return Drawing(
                id: id, projectId: project.id, name: name, fileName: "\(id.uuidString).pdf", pageCount: 2,
                createdDate: t0,
                calibrations: [
                    PageCalibration(id: UUID(), pageIndex: 1, pointA: PDFPoint(x: 0, y: 0), pointB: PDFPoint(x: 10, y: 0),
                                    realDistanceMM: 1000, enteredUnit: .mm, enteredValue: 1000, mmPerPDFUnit: 100,
                                    calibratedDate: t0),
                    PageCalibration(id: UUID(), pageIndex: 0, pointA: PDFPoint(x: 0, y: 0), pointB: PDFPoint(x: 5, y: 0),
                                    realDistanceMM: 500, enteredUnit: .mm, enteredValue: 500, mmPerPDFUnit: 100,
                                    calibratedDate: t0)
                ]
            )
        }
        func issue(_ drawing: Drawing, _ number: Int, photos: [IssuePhoto] = []) -> Issue {
            Issue(drawingId: drawing.id, pageIndex: 0, pdfX: 10, pdfY: 20, number: number, title: "Issue \(number)",
                  createdDate: t0, photos: photos)
        }
        func area(_ project: Project, _ drawing: Drawing) -> Area {
            Area(projectId: project.id, drawingId: drawing.id, pageIndex: 0, name: "Zone",
                 vertices: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 0, y: 1)],
                 createdDate: t0, updatedDate: t0)
        }

        let d1 = drawing(projectA, "D1")
        let d2 = drawing(projectA, "D2")
        // Photos inserted out of chronological order: grouped fetch must sort per issue.
        let pLate = IssuePhoto(fileName: "late.jpg", createdDate: t0.addingTimeInterval(60))
        let pEarly = IssuePhoto(fileName: "early.jpg", createdDate: t0.addingTimeInterval(10))
        let i1 = issue(d1, 1, photos: [pLate, pEarly])
        let i2 = issue(d1, 2)
        let i3 = issue(d2, 3, photos: [IssuePhoto(fileName: "d2.jpg", createdDate: t0)])
        let a1 = area(projectA, d2)
        var dataA = AppData(project: projectA, drawings: [d1, d2], issues: [i1, i2, i3], areas: [a1])

        // Project B written through the existing full-graph writer.
        let dB = drawing(projectB, "DB")
        let iB = issue(dB, 1, photos: [IssuePhoto(fileName: "b.jpg", createdDate: t0)])
        try db.persistProjectWorkspace(project: projectB, folders: [], drawings: [dB], areas: [], issues: [iB])
        let bRowsBefore = try count(db, "SELECT COUNT(*) FROM issues WHERE project_id = ?", [projectB.id.uuidString])

        // Initial save from an empty baseline (fresh workspace) inserts everything.
        var saver = Saver(db: db, baseline: SQLiteWorkspaceBaseline(data: AppData(project: projectA)))
        try db.ensureProject(projectA)
        _ = try saver.save(dataA)
        try expect(try db.fetchIssues(projectId: projectA.id).count == 3, "initial delta save inserts 3 issues", &checks)

        // Grouped fetch ordering and relationships.
        let fetchedIssues = try db.fetchIssues(projectId: projectA.id)
        let fetchedI1 = fetchedIssues.first { $0.id == i1.id }
        try expect(fetchedI1?.photos.map(\.fileName) == ["early.jpg", "late.jpg"],
                   "grouped photo fetch keeps created_at order per issue", &checks)
        try expect(fetchedIssues.first { $0.id == i2.id }?.photos.isEmpty == true,
                   "issue without photos gets an empty array", &checks)
        let fetchedDrawings = try db.fetchDrawings(projectId: projectA.id)
        try expect(fetchedDrawings.allSatisfy { $0.calibrations.map(\.pageIndex) == [0, 1] },
                   "grouped calibration fetch keeps page_index order per drawing", &checks)
        let unknownDrawings = try db.fetchDrawings(projectId: UUID())
        let unknownIssues = try db.fetchIssues(projectId: UUID())
        try expect(unknownDrawings.isEmpty && unknownIssues.isEmpty,
                   "grouped fetches on an unknown project return empty", &checks)
        try expect(try db.fetchIssues(projectId: projectB.id).first?.photos.count == 1,
                   "grouped fetch does not mix photos across projects", &checks)

        // Scenario 1 + 2: edit an issue, then repeatedly.
        for round in 1...3 {
            dataA.issues[1].title = "Edited \(round)"
            let delta = try saver.save(dataA)
            try expect(delta.upsertIssues.map(\.id) == [i2.id] && delta.deletedIssueIds.isEmpty,
                       "edit round \(round) upserts only the edited issue", &checks)
        }
        try expect(try db.fetchIssues(projectId: projectA.id).first { $0.id == i2.id }?.title == "Edited 3",
                   "repeated edits persist the last value", &checks)
        try expect(try saver.save(dataA).isEmpty, "save without changes produces an empty delta", &checks)

        // Scenario 3: delete an issue with photos (issue_photos cascade; project_photos link set null).
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO project_photos (id, project_id, file_name, taken_at, issue_id, created_at, updated_at)
                VALUES (?, ?, 'Photos/x.jpg', ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, projectA.id.uuidString, "2025-01-01T00:00:00.000Z",
                            i1.id.uuidString, "2025-01-01T00:00:00.000Z", "2025-01-01T00:00:00.000Z"]
            )
        }
        dataA.issues.removeAll { $0.id == i1.id }
        _ = try saver.save(dataA)
        try expect(try count(db, "SELECT COUNT(*) FROM issue_photos WHERE issue_id = ?", [i1.id.uuidString]) == 0,
                   "deleted issue's photo rows are removed", &checks)
        try expect(try count(db, "SELECT COUNT(*) FROM issue_photos WHERE issue_id = ?", [i3.id.uuidString]) == 1,
                   "other issues keep their photo rows", &checks)
        try expect(try count(db, "SELECT COUNT(*) FROM project_photos WHERE issue_id IS NULL") == 1,
                   "documentation photo survives with its issue link cleared", &checks)

        // Scenario 5 + 9: a remote pull wrote a folder that memory never reloaded.
        let remoteFolderId = UUID()
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "INSERT INTO drawing_folders (id, project_id, parent_folder_id, name, sort_order, created_at) VALUES (?, ?, NULL, 'Remote', 9, ?)",
                arguments: [remoteFolderId.uuidString, projectA.id.uuidString, "2025-01-01T00:00:00.000Z"]
            )
        }
        dataA.issues[0].title = "Edit after unreloaded pull"
        _ = try saver.save(dataA)
        try expect(try count(db, "SELECT COUNT(*) FROM drawing_folders WHERE id = ?", [remoteFolderId.uuidString]) == 1,
                   "unrelated save keeps a pulled-but-unreloaded folder", &checks)

        // Scenario 5a: a pull renamed D2 and moved it into the pulled folder; memory still has the
        // old metadata. Editing an issue on D2 must not revert the newer row from memory.
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE drawings SET name = 'Remote name', revision = 'R2', folder_id = ? WHERE id = ?",
                arguments: [remoteFolderId.uuidString, d2.id.uuidString]
            )
        }
        guard let i3Index = dataA.issues.firstIndex(where: { $0.id == i3.id }) else {
            throw Failure(description: "FAILED: fixture lost issue i3")
        }
        dataA.issues[i3Index].title = "Edit on remotely renamed drawing"
        let parentDelta = try saver.save(dataA)
        let d2Row = try db.dbQueue.read { conn in
            try Row.fetchOne(conn, sql: "SELECT name, revision, folder_id FROM drawings WHERE id = ?", arguments: [d2.id.uuidString])
        }
        let d2Name: String? = d2Row?["name"]
        let d2Revision: String? = d2Row?["revision"]
        let d2Folder: String? = d2Row?["folder_id"]
        try expect(parentDelta.upsertDrawings.isEmpty && parentDelta.ensureParentDrawings.map(\.id) == [d2.id],
                   "issue edit lists its parent only as ensure-if-missing", &checks)
        try expect(d2Name == "Remote name" && d2Revision == "R2" && d2Folder == remoteFolderId.uuidString,
                   "issue edit keeps newer pulled drawing name / revision / folder", &checks)

        // Scenario 5b: pull tombstoned D1 in SQLite (memory stale), then the user pins a new issue on it.
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM issues WHERE drawing_id = ?", arguments: [d1.id.uuidString])
            try conn.execute(sql: "DELETE FROM drawings WHERE id = ?", arguments: [d1.id.uuidString])
        }
        saver.baseline.issues.removeValue(forKey: i2.id)   // pull removed it; baseline/memory now disagree with DB
        dataA.issues.removeAll { $0.id == i2.id }
        let i4 = issue(d1, 4)
        dataA.issues.append(i4)
        _ = try saver.save(dataA)
        try expect(try count(db, "SELECT COUNT(*) FROM issues WHERE id = ?", [i4.id.uuidString]) == 1,
                   "child save re-upserts its missing parent drawing instead of failing the FK", &checks)

        // Scenario 7 + 8: a failing save rolls back completely and the next save retries it.
        let orphan = Issue(drawingId: UUID(), pageIndex: 0, pdfX: 0, pdfY: 0, number: 99, title: "No parent anywhere")
        dataA.issues[0].title = "Change inside failed save"
        dataA.issues.append(orphan)
        var failed = false
        do { _ = try saver.save(dataA) } catch { failed = true }
        try expect(failed, "save with an unresolvable FK throws", &checks)
        try expect(try db.fetchIssues(projectId: projectA.id).first { $0.id == dataA.issues[0].id }?.title != "Change inside failed save",
                   "failed save is rolled back atomically", &checks)
        dataA.issues.removeAll { $0.id == orphan.id }
        _ = try saver.save(dataA)
        try expect(try db.fetchIssues(projectId: projectA.id).first { $0.id == dataA.issues[0].id }?.title == "Change inside failed save",
                   "next save after a failure re-applies the rolled-back change", &checks)

        // Scenario 4: delete a drawing with issues and areas (AppStore.deleteDrawing removes dependents).
        dataA.drawings.removeAll { $0.id == d2.id }
        dataA.issues.removeAll { $0.drawingId == d2.id }
        dataA.areas.removeAll { $0.drawingId == d2.id }
        _ = try saver.save(dataA)
        let d2Drawings = try count(db, "SELECT COUNT(*) FROM drawings WHERE id = ?", [d2.id.uuidString])
        let d2Areas = try count(db, "SELECT COUNT(*) FROM areas WHERE drawing_id = ?", [d2.id.uuidString])
        let d2Calibrations = try count(db, "SELECT COUNT(*) FROM page_calibrations WHERE drawing_id = ?", [d2.id.uuidString])
        try expect(d2Drawings == 0 && d2Areas == 0 && d2Calibrations == 0,
                   "drawing delete removes its areas and calibrations", &checks)
        try expect(try count(db, "SELECT COUNT(*) FROM issues WHERE id = ?", [i4.id.uuidString]) == 1,
                   "issues on other drawings survive a drawing delete", &checks)

        // Scenario 10 (isolation): a forged delete id from project B is ignored by the project guard.
        var forged = ProjectWorkspaceDelta()
        forged.deletedIssueIds = [iB.id]
        forged.deletedDrawingIds = [dB.id]
        try db.persistProjectWorkspaceDelta(project: projectA, delta: forged)
        let bRowsAfter = try count(db, "SELECT COUNT(*) FROM issues WHERE project_id = ?", [projectB.id.uuidString])
        let bDrawings = try count(db, "SELECT COUNT(*) FROM drawings WHERE id = ?", [dB.id.uuidString])
        try expect(bRowsAfter == bRowsBefore && bDrawings == 1,
                   "deletes are scoped to the saving project", &checks)

        let integrity = try db.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        let fkViolations = try db.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        try expect(integrity == "ok" && fkViolations == 0, "integrity_check ok, no FK violations", &checks)
    }
}
#endif
