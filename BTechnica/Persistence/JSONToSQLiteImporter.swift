import Foundation
import GRDB

/// One-time, idempotent import of existing JSON workspaces into SQLite.
///
/// - Preserves all entity UUIDs, PDF coordinates, and relative file names.
/// - Leaves original JSON and PDF/photo files in place (recovery copies).
/// - Uses `INSERT OR IGNORE` + `json_import_runs` so re-running never duplicates rows.
final class JSONToSQLiteImporter {
    private let database: AppDatabase
    private let fileManager: FileManager
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(database: AppDatabase, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
    }

    func importAll() throws -> JSONImportReport {
        var report = JSONImportReport()

        let userSharedURL = database.rootURL.appendingPathComponent("userdata.json")
        report.sources.append(importUserShared(at: userSharedURL))

        let projectsRoot = database.rootURL.appendingPathComponent("Projects", isDirectory: true)
        if fileManager.fileExists(atPath: projectsRoot.path) {
            let projectDirs = (try? fileManager.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for dir in projectDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let appdata = dir.appendingPathComponent("appdata.json")
                report.sources.append(importProject(at: appdata))
            }
        }

        return report
    }

    // MARK: - User shared

    private func importUserShared(at url: URL) -> JSONImportReport.SourceResult {
        let sourceKey = "user_shared:\(database.userId.uuidString)"
        do {
            if try alreadyImported(sourceKey) {
                return .init(sourceKey: sourceKey, skippedAlreadyImported: true, counts: [:], errorDescription: nil)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                // No userdata yet — skip without marking so a later file can still import once.
                return .init(
                    sourceKey: sourceKey,
                    skippedAlreadyImported: false,
                    counts: [:],
                    errorDescription: nil
                )
            }

            let data = try Data(contentsOf: url)
            let shared = try decoder.decode(UserSharedData.self, from: data)
            try ensureJSONRecoveryCopy(of: url)

            var counts: [String: Int] = [:]
            try database.dbQueue.write { db in
                counts["contractors"] = try insertContractors(shared.contractors, db: db)
                counts["disciplines"] = try insertDisciplines(shared.disciplines, db: db)
                let equipmentResult = try insertEquipment(shared.equipment, db: db)
                counts["equipment_items"] = equipmentResult.items
                counts["equipment_events"] = equipmentResult.events
                try recordImportRun(sourceKey: sourceKey, sourcePath: url.path, counts: counts, db: db)
            }
            return .init(sourceKey: sourceKey, skippedAlreadyImported: false, counts: counts, errorDescription: nil)
        } catch {
            return .init(
                sourceKey: sourceKey,
                skippedAlreadyImported: false,
                counts: [:],
                errorDescription: error.localizedDescription
            )
        }
    }

    // MARK: - Project local

    private func importProject(at url: URL) -> JSONImportReport.SourceResult {
        let projectFolderName = url.deletingLastPathComponent().lastPathComponent
        let sourceKey = "project:\(projectFolderName)"
        do {
            if try alreadyImported(sourceKey) {
                return .init(sourceKey: sourceKey, skippedAlreadyImported: true, counts: [:], errorDescription: nil)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return .init(sourceKey: sourceKey, skippedAlreadyImported: false, counts: [:], errorDescription: "missing appdata.json")
            }

            let data = try Data(contentsOf: url)
            let projectData = try decodeProjectLocal(from: data)
            try ensureJSONRecoveryCopy(of: url)

            var counts: [String: Int] = [:]
            try database.dbQueue.write { db in
                counts = try insertProjectLocal(projectData, db: db)
                try recordImportRun(sourceKey: sourceKey, sourcePath: url.path, counts: counts, db: db)
            }
            return .init(sourceKey: sourceKey, skippedAlreadyImported: false, counts: counts, errorDescription: nil)
        } catch {
            return .init(
                sourceKey: sourceKey,
                skippedAlreadyImported: false,
                counts: [:],
                errorDescription: error.localizedDescription
            )
        }
    }

    /// Accepts `ProjectLocalData` or legacy combined `AppData` shapes.
    private func decodeProjectLocal(from data: Data) throws -> ProjectLocalData {
        if let local = try? decoder.decode(ProjectLocalData.self, from: data) {
            return local
        }
        let combined = try decoder.decode(AppData.self, from: data)
        return ProjectLocalData(
            project: combined.project,
            drawingFolders: combined.drawingFolders,
            drawings: combined.drawings,
            issues: combined.issues,
            areas: combined.areas,
            schemaVersion: combined.schemaVersion
        )
    }

    // MARK: - Inserts (INSERT OR IGNORE → repeatable)

    private func insertProjectLocal(_ data: ProjectLocalData, db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let projectId = data.project.id

        try db.execute(
            sql: """
            INSERT OR IGNORE INTO projects (id, name, created_at)
            VALUES (?, ?, ?)
            """,
            arguments: [
                projectId.uuidString,
                data.project.name,
                SQLiteDateCoding.string(from: data.project.createdDate)
            ]
        )
        counts["projects"] = 1

        var folders = 0
        for folder in data.drawingFolders {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO drawing_folders
                  (id, project_id, parent_folder_id, name, sort_order, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    folder.id.uuidString,
                    folder.projectId.uuidString,
                    folder.parentFolderId?.uuidString,
                    folder.name,
                    folder.sortOrder,
                    SQLiteDateCoding.string(from: folder.createdDate)
                ]
            )
            folders += 1
        }
        counts["drawing_folders"] = folders

        var drawings = 0
        var calibrations = 0
        for drawing in data.drawings {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO drawings
                  (id, project_id, folder_id, name, file_name, page_count, created_at,
                   revision, discipline, location, drawing_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    drawing.id.uuidString,
                    drawing.projectId.uuidString,
                    drawing.folderId?.uuidString,
                    drawing.name,
                    drawing.fileName,
                    drawing.pageCount,
                    SQLiteDateCoding.string(from: drawing.createdDate),
                    drawing.revision,
                    drawing.discipline,
                    drawing.location,
                    drawing.drawingDate.map(SQLiteDateCoding.string(from:))
                ]
            )
            drawings += 1

            for cal in drawing.calibrations {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO page_calibrations
                      (id, drawing_id, page_index,
                       point_a_x, point_a_y, point_b_x, point_b_y,
                       real_distance_mm, entered_unit, entered_value,
                       mm_per_pdf_unit, calibrated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        cal.id.uuidString,
                        drawing.id.uuidString,
                        cal.pageIndex,
                        cal.pointA.x,
                        cal.pointA.y,
                        cal.pointB.x,
                        cal.pointB.y,
                        cal.realDistanceMM,
                        cal.enteredUnit.rawValue,
                        cal.enteredValue,
                        cal.mmPerPDFUnit,
                        SQLiteDateCoding.string(from: cal.calibratedDate)
                    ]
                )
                calibrations += 1
            }
        }
        counts["drawings"] = drawings
        counts["page_calibrations"] = calibrations

        var areas = 0
        for area in data.areas {
            let verticesJSON = try encodeVertices(area.vertices)
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO areas
                  (id, project_id, drawing_id, page_index, name, vertices_json,
                   color, opacity, is_visible, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    area.id.uuidString,
                    area.projectId.uuidString,
                    area.drawingId.uuidString,
                    area.pageIndex,
                    area.name,
                    verticesJSON,
                    area.color,
                    area.opacity,
                    area.isVisible,
                    SQLiteDateCoding.string(from: area.createdDate),
                    SQLiteDateCoding.string(from: area.updatedDate)
                ]
            )
            areas += 1
        }
        counts["areas"] = areas

        var issues = 0
        var photos = 0
        for issue in data.issues {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO issues
                  (id, project_id, drawing_id, page_index, pdf_x, pdf_y, area_id,
                   number, title, details, status, discipline, contractor, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    issue.id.uuidString,
                    projectId.uuidString,
                    issue.drawingId.uuidString,
                    issue.pageIndex,
                    issue.pdfX,
                    issue.pdfY,
                    issue.areaId?.uuidString,
                    issue.number,
                    issue.title,
                    issue.details,
                    issue.status.rawValue,
                    issue.discipline,
                    issue.contractor,
                    SQLiteDateCoding.string(from: issue.createdDate)
                ]
            )
            issues += 1

            for photo in issue.photos {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO issue_photos (id, issue_id, file_name, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        photo.id.uuidString,
                        issue.id.uuidString,
                        photo.fileName,
                        SQLiteDateCoding.string(from: photo.createdDate)
                    ]
                )
                photos += 1
            }
        }
        counts["issues"] = issues
        counts["issue_photos"] = photos

        return counts
    }

    private func insertContractors(_ contractors: [Contractor], db: Database) throws -> Int {
        let owner = database.userId.uuidString
        for c in contractors {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO contractors (id, owner_id, name, notes, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    c.id.uuidString,
                    owner,
                    c.name,
                    c.notes,
                    SQLiteDateCoding.string(from: c.createdDate)
                ]
            )
        }
        return contractors.count
    }

    private func insertDisciplines(_ disciplines: [Discipline], db: Database) throws -> Int {
        let owner = database.userId.uuidString
        for d in disciplines {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO disciplines (id, owner_id, name, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    d.id.uuidString,
                    owner,
                    d.name,
                    SQLiteDateCoding.string(from: d.createdDate)
                ]
            )
        }
        return disciplines.count
    }

    private func insertEquipment(_ items: [EquipmentItem], db: Database) throws -> (items: Int, events: Int) {
        let owner = database.userId.uuidString
        var eventCount = 0
        for item in items {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO equipment_items
                  (id, owner_id, item, category, identifier, notes,
                   issued_to, location, issued_at, returned_at, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id.uuidString,
                    owner,
                    item.item,
                    item.category,
                    item.identifier,
                    item.notes,
                    item.issuedTo,
                    item.location,
                    item.issuedDate.map(SQLiteDateCoding.string(from:)),
                    item.returnedDate.map(SQLiteDateCoding.string(from:)),
                    item.status.rawValue
                ]
            )
            for event in item.history {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO equipment_events
                      (id, equipment_id, event_at, event_type, person, location, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        event.id.uuidString,
                        item.id.uuidString,
                        SQLiteDateCoding.string(from: event.date),
                        event.type.rawValue,
                        event.person,
                        event.location,
                        event.notes
                    ]
                )
                eventCount += 1
            }
        }
        return (items.count, eventCount)
    }

    // MARK: - Import run tracking

    private func alreadyImported(_ sourceKey: String) throws -> Bool {
        try database.dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM json_import_runs WHERE source_key = ?)",
                arguments: [sourceKey]
            ) ?? false
        }
    }

    private func markImported(sourceKey: String, sourcePath: String, counts: [String: Int]) throws {
        try database.dbQueue.write { db in
            try recordImportRun(sourceKey: sourceKey, sourcePath: sourcePath, counts: counts, db: db)
        }
    }

    private func recordImportRun(
        sourceKey: String,
        sourcePath: String,
        counts: [String: Int],
        db: Database
    ) throws {
        let countsJSON = try String(
            data: JSONEncoder().encode(counts),
            encoding: .utf8
        ) ?? "{}"
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO json_import_runs
              (source_key, source_path, imported_at, record_counts_json)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [
                sourceKey,
                sourcePath,
                SQLiteDateCoding.string(from: Date()),
                countsJSON
            ]
        )
    }

    /// Copies `appdata.json` / `userdata.json` beside the original once as
    /// `*-pre-sqlite.json` so originals remain untouched recovery copies.
    private func ensureJSONRecoveryCopy(of url: URL) throws {
        let backupName = url.deletingPathExtension().lastPathComponent + "-pre-sqlite.json"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupName)
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func encodeVertices(_ vertices: [PDFPoint]) throws -> String {
        struct PointDTO: Encodable {
            let x: Double
            let y: Double
        }
        let payload = vertices.map { PointDTO(x: $0.x, y: $0.y) }
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "JSONToSQLiteImporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode area vertices JSON"]
            )
        }
        return string
    }
}
