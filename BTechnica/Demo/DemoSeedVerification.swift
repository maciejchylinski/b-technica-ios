// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB
import PDFKit

/// Verifies the demo seeder end to end on an isolated temporary database:
/// first seed, idempotent second seed, forced re-seed without duplicates, no outbox or
/// file-transfer rows, files on disk, drawings readable by PDFKit with every pin and area
/// inside the real page bounds, and searchable text in every document (app extractor).
/// Launch argument `-BTVerifyDemoSeed`; exit code 0 = passed.
enum DemoSeedVerification {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifyDemoSeed") else { return }
        var log: [String] = []
        let passed: Bool
        do {
            try run(&log)
            passed = true
        } catch {
            log.append("FAILED: \(error)")
            passed = false
        }
        let text = (["passed=\(passed)"] + log).joined(separator: "\n")
        try? text.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bt-demo-seed-verify.txt"),
                        atomically: true, encoding: .utf8)
        fputs("BT_DEMO_SEED_VERIFY \(text)\n", stderr)
        exit(passed ? 0 : 1)
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ label: String, _ log: inout [String]) throws {
        guard condition else { throw Failure(description: label) }
        log.append("ok: \(label)")
    }

    private static func counts(_ db: AppDatabase) throws -> [String: Int] {
        let tables = ["projects", "drawing_folders", "drawings", "page_calibrations", "areas", "issues", "issue_photos",
                      "project_photos", "photo_albums", "schedules", "schedule_phases", "schedule_tasks",
                      "schedule_task_dependencies", "project_documents", "project_document_folders", "project_notes",
                      "contact_companies", "contact_people", "project_contacts", "equipment_items",
                      "equipment_checkouts", "equipment_events", "contractors", "disciplines", "sync_outbox",
                      "file_transfers", "drawing_page_mappings"]
        return try db.dbQueue.read { conn in
            var out: [String: Int] = [:]
            for table in tables {
                out[table] = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return out
        }
    }

    // swiftlint:disable:next function_body_length
    private static func run(_ log: inout [String]) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("btechnica-demo-seed-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let manifest = try DemoDataSeeder.loadManifest(bundle: .main)
        let db = try AppDatabase.open(userId: DemoMode.userId, at: root.appendingPathComponent("btechnica.sqlite"),
                                      rootURL: root)
        let seeder = DemoDataSeeder(database: db)

        let first = try seeder.seed()
        try expect(first.seeded, "first run seeds", &log)
        let c1 = try counts(db)
        let projects = manifest.projects
        try expect(c1["projects"] == projects.count, "projects = \(projects.count)", &log)
        try expect(c1["drawings"] == projects.reduce(0) { $0 + $1.drawings.count }, "drawings match manifest", &log)
        try expect(c1["issues"] == projects.reduce(0) { $0 + $1.issues.count }, "issues match manifest", &log)
        try expect(c1["areas"] == projects.reduce(0) { $0 + $1.areas.count }, "areas match manifest", &log)
        try expect(c1["issue_photos"] == projects.reduce(0) { $0 + $1.issues.reduce(0) { $0 + $1.photos.count } },
                   "issue photos match manifest", &log)
        try expect(c1["project_photos"] == projects.reduce(0) { $0 + $1.photos.count }, "documentation photos match", &log)
        try expect(c1["schedule_tasks"] == projects.reduce(0) { $0 + ($1.schedule?.tasks.count ?? 0) }, "schedule tasks", &log)
        try expect(c1["project_documents"] == projects.reduce(0) { $0 + $1.documents.count }, "documents", &log)
        try expect(c1["project_notes"] == projects.reduce(0) { $0 + $1.notes.count }, "notes", &log)
        try expect(c1["contact_people"] == manifest.people.count, "people", &log)
        try expect(c1["equipment_items"] == manifest.equipment.count, "equipment", &log)
        try expect(c1["sync_outbox"] == 0, "no outbox rows (nothing queued for Supabase)", &log)
        try expect(c1["file_transfers"] == 0, "no file transfers (no uploads/downloads queued)", &log)
        try expect(c1["drawing_page_mappings"] == 0, "no remote page mappings (local-only drawings)", &log)

        let statusRows = try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: "SELECT status, COUNT(*) AS n FROM equipment_items GROUP BY status")
        }
        var statuses: [String: Int] = [:]
        for row in statusRows {
            let status: String = row["status"]
            let count: Int = row["n"]
            statuses[status] = count
        }
        try expect((statuses["issued"] ?? 0) > 0 && (statuses["available"] ?? 0) > 0 && (statuses["damaged"] ?? 0) > 0,
                   "equipment has issued, available and damaged items \(statuses)", &log)

        // Files on disk + PDFKit geometry checks.
        for project in projects {
            let projectRoot = root.appendingPathComponent("Projects/\(project.id)", isDirectory: true)
            let drawings = try db.fetchDrawings(projectId: UUID(uuidString: project.id)!)
            var bounds: [String: [CGRect]] = [:]
            for drawing in drawings {
                let url = projectRoot.appendingPathComponent("Drawings/\(drawing.fileName)")
                guard let pdf = PDFDocument(url: url) else { throw Failure(description: "PDFKit cannot open \(drawing.name)") }
                try expect(pdf.pageCount == drawing.pageCount, "\(drawing.name): \(pdf.pageCount) page(s)", &log)
                bounds[drawing.id.uuidString] = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox) }
            }
            for issue in try db.fetchIssues(projectId: UUID(uuidString: project.id)!) {
                guard let rect = bounds[issue.drawingId.uuidString]?[safe: issue.pageIndex] else {
                    throw Failure(description: "issue #\(issue.number) has no drawing page")
                }
                guard rect.contains(CGPoint(x: issue.pdfX, y: issue.pdfY)) else {
                    throw Failure(description: "issue #\(issue.number) pin outside page bounds")
                }
                for photo in issue.photos {
                    let url = projectRoot.appendingPathComponent("IssuePhotos/\(photo.fileName)")
                    guard fm.fileExists(atPath: url.path) else { throw Failure(description: "missing issue photo file") }
                }
            }
            log.append("ok: \(project.name): every pin is inside its PDF page and every issue photo exists")
            for area in try db.fetchAreas(projectId: UUID(uuidString: project.id)!) {
                guard let rect = bounds[area.drawingId.uuidString]?[safe: area.pageIndex],
                      area.vertices.allSatisfy({ rect.contains($0.cgPoint) }) else {
                    throw Failure(description: "area \(area.name) outside its page")
                }
            }
            for photo in try db.fetchProjectPhotos(projectId: UUID(uuidString: project.id)!) {
                let thumb = photo.thumbnailFileName.map { projectRoot.appendingPathComponent($0).path } ?? ""
                guard fm.fileExists(atPath: projectRoot.appendingPathComponent(photo.fileName).path),
                      fm.fileExists(atPath: thumb) else {
                    throw Failure(description: "missing documentation photo file \(photo.fileName)")
                }
            }
            for document in try db.fetchProjectDocuments(projectId: UUID(uuidString: project.id)!) {
                let url = projectRoot.appendingPathComponent(document.fileRelativePath)
                guard let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) else {
                    throw Failure(description: "document \(document.name) unreadable")
                }
                let result = DocumentTextExtractor.extract(page: page, pageIndex: 0, allowOCR: false)
                guard result.method == .pdfText, result.text.count > 200 else {
                    throw Failure(description: "document \(document.name) has no usable text layer")
                }
                guard document.indexStatus == .pending else {
                    throw Failure(description: "document \(document.name) should wait for the app indexer")
                }
            }
            log.append("ok: \(project.name): photos on disk, documents have a PDF text layer (pending indexing)")
        }

        let hydro = try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: "SELECT id FROM project_documents WHERE name LIKE 'ST-04%'").count
        }
        try expect(hydro == 1, "ST-04 waterproofing specification present", &log)

        let second = try seeder.seed()
        try expect(!second.seeded, "second run is a no-op (seed version marker)", &log)
        try expect(try counts(db) == c1, "second run leaves every table unchanged", &log)

        let forced = try seeder.seed(force: true)
        try expect(forced.seeded, "forced reset re-seeds", &log)
        try expect(try counts(db) == c1, "forced reset recreates the same rows (no duplicates)", &log)

        let integrity = try db.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        let fkViolations = try db.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        try expect(integrity == "ok" && fkViolations == 0, "integrity_check ok, no FK violations", &log)

        // The seeder refuses any database that is not the demo user's.
        let other = try AppDatabase.open(userId: UUID(), at: root.appendingPathComponent("other.sqlite"), rootURL: root)
        do {
            _ = try DemoDataSeeder(database: other).seed()
            throw Failure(description: "seeder accepted a non-demo database")
        } catch DemoDataSeeder.SeedError.notDemoDatabase {
            log.append("ok: seeder refuses non-demo databases")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
