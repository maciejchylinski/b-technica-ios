// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB

/// Targeted migration check against a **copy** of fixture JSON (not live Documents).
/// Used for DEBUG verification; does not touch the user's real workspace.
enum JSONImportVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
        var firstPassCounts: [String: Int]
        var secondPassRowTotals: [String: Int]
    }

    /// Builds a temp user tree, imports twice, asserts UUID/coord/path preservation and no duplicates.
    static func run() -> Result {
        do {
            return try runThrowing()
        } catch {
            return Result(
                passed: false,
                message: "Verification threw: \(error.localizedDescription)",
                firstPassCounts: [:],
                secondPassRowTotals: [:]
            )
        }
    }

    private static func runThrowing() throws -> Result {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-sqlite-verify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let drawingId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let calId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let issueId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        let photoId = UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111")!
        let areaId = UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")!
        let folderId = UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333")!
        let contractorId = UUID(uuidString: "01010101-0202-0303-0404-050505050505")!
        let disciplineId = UUID(uuidString: "06060606-0707-0808-0909-0A0A0A0A0A0A")!
        let equipmentId = UUID(uuidString: "0B0B0B0B-0C0C-0D0D-0E0E-0F0F0F0F0F0F")!
        let eventId = UUID(uuidString: "10101010-1111-1212-1313-141414141414")!

        let pdfX = 123.456
        let pdfY = 789.012
        let fileName = "\(drawingId.uuidString).pdf"
        let photoName = "\(photoId.uuidString).jpg"

        let projectRoot = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectRoot.appendingPathComponent("Drawings", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: projectRoot.appendingPathComponent("IssuePhotos", isDirectory: true),
            withIntermediateDirectories: true
        )

        // Empty placeholder files (paths preserved in JSON; bytes not required for import).
        try Data().write(to: projectRoot.appendingPathComponent("Drawings").appendingPathComponent(fileName))
        try Data().write(to: projectRoot.appendingPathComponent("IssuePhotos").appendingPathComponent(photoName))

        // PageCalibration.init always creates a new id — pin a known UUID via Codable round-trip.
        let calWithId = try forceCalibrationId(
            PageCalibration(
                pageIndex: 0,
                pointA: PDFPoint(x: 10.5, y: 20.5),
                pointB: PDFPoint(x: 110.5, y: 20.5),
                enteredValue: 5,
                enteredUnit: .m
            ),
            id: calId
        )

        let drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: "Level 1 Plan",
            fileName: fileName,
            pageCount: 1,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "A",
            discipline: "Architectural",
            location: "L1",
            drawingDate: Date(timeIntervalSince1970: 1_690_000_000),
            calibrations: [calWithId]
        )

        let area = Area(
            id: areaId,
            projectId: projectId,
            drawingId: drawingId,
            pageIndex: 0,
            name: "Zone A",
            vertices: [
                PDFPoint(x: 1, y: 2),
                PDFPoint(x: 3, y: 4),
                PDFPoint(x: 5, y: 6)
            ],
            color: "#007AFF",
            opacity: 0.35,
            isVisible: true,
            createdDate: Date(timeIntervalSince1970: 1_700_000_100),
            updatedDate: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let issue = Issue(
            id: issueId,
            drawingId: drawingId,
            pageIndex: 0,
            pdfX: pdfX,
            pdfY: pdfY,
            areaId: areaId,
            number: 7,
            title: "Crack",
            details: "North wall",
            status: .open,
            discipline: "Structural",
            contractor: "Acme",
            createdDate: Date(timeIntervalSince1970: 1_700_000_300),
            photos: [
                IssuePhoto(
                    id: photoId,
                    fileName: photoName,
                    createdDate: Date(timeIntervalSince1970: 1_700_000_400)
                )
            ]
        )

        let projectData = ProjectLocalData(
            project: Project(
                id: projectId,
                name: "Demo Site",
                createdDate: Date(timeIntervalSince1970: 1_600_000_000)
            ),
            drawingFolders: [
                DrawingFolder(
                    id: folderId,
                    projectId: projectId,
                    parentFolderId: nil,
                    name: "Architectural",
                    sortOrder: 1,
                    createdDate: Date(timeIntervalSince1970: 1_650_000_000)
                )
            ],
            drawings: [drawing],
            issues: [issue],
            areas: [area]
        )

        let userShared = UserSharedData(
            contractors: [
                Contractor(
                    id: contractorId,
                    name: "Acme",
                    notes: "Electrical",
                    createdDate: Date(timeIntervalSince1970: 1_640_000_000)
                )
            ],
            equipment: [
                EquipmentItem(
                    id: equipmentId,
                    item: "Laser",
                    category: "Tool",
                    identifier: "SN-1",
                    notes: nil,
                    issuedTo: "Sam",
                    location: "Site",
                    issuedDate: Date(timeIntervalSince1970: 1_700_100_000),
                    returnedDate: nil,
                    status: .issued,
                    history: [
                        EquipmentEvent(
                            id: eventId,
                            date: Date(timeIntervalSince1970: 1_700_100_000),
                            type: .issued,
                            person: "Sam",
                            location: "Site",
                            notes: nil
                        )
                    ]
                )
            ],
            disciplines: [
                Discipline(
                    id: disciplineId,
                    name: "Structural",
                    createdDate: Date(timeIntervalSince1970: 1_630_000_000)
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(projectData).write(to: projectRoot.appendingPathComponent("appdata.json"))
        try encoder.encode(userShared).write(to: root.appendingPathComponent("userdata.json"))

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)

        let first = try db.importJSONSources(fileManager: fm)
        let second = try db.importJSONSources(fileManager: fm)

        guard first.failedSourceCount == 0 else {
            return Result(
                passed: false,
                message: "First import had failures: \(first.sources)",
                firstPassCounts: [:],
                secondPassRowTotals: [:]
            )
        }
        guard second.skippedSourceCount == first.sources.count,
              second.importedSourceCount == 0
        else {
            return Result(
                passed: false,
                message: "Second pass should skip all sources (idempotent marker). second=\(second)",
                firstPassCounts: [:],
                secondPassRowTotals: [:]
            )
        }

        // Aggregate first-pass declared counts
        var firstCounts: [String: Int] = [:]
        for source in first.sources {
            for (k, v) in source.counts {
                firstCounts[k, default: 0] += v
            }
        }

        let totals = try db.dbQueue.read { database -> [String: Int] in
            let tables = [
                "projects", "drawing_folders", "drawings", "page_calibrations",
                "areas", "issues", "issue_photos",
                "contractors", "disciplines", "equipment_items", "equipment_events"
            ]
            var map: [String: Int] = [:]
            for table in tables {
                map[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
            return map
        }

        // Expect exactly one of each fixture entity (second pass must not duplicate).
        let expected: [String: Int] = [
            "projects": 1,
            "drawing_folders": 1,
            "drawings": 1,
            "page_calibrations": 1,
            "areas": 1,
            "issues": 1,
            "issue_photos": 1,
            "contractors": 1,
            "disciplines": 1,
            "equipment_items": 1,
            "equipment_events": 1
        ]
        for (table, want) in expected {
            guard totals[table] == want else {
                return Result(
                    passed: false,
                    message: "Row count mismatch for \(table): got \(totals[table] ?? -1), want \(want)",
                    firstPassCounts: firstCounts,
                    secondPassRowTotals: totals
                )
            }
        }

        // Spot-check UUID, PDF coords, file paths
        try db.dbQueue.read { database in
            guard let issueRow = try Row.fetchOne(
                database,
                sql: "SELECT id, pdf_x, pdf_y, number FROM issues WHERE id = ?",
                arguments: [issueId.uuidString]
            ) else {
                throw VerificationError.mismatch("issue row missing")
            }
            let storedX: Double = issueRow["pdf_x"]
            let storedY: Double = issueRow["pdf_y"]
            let storedNumber: Int = issueRow["number"]
            guard storedX == pdfX, storedY == pdfY, storedNumber == 7 else {
                throw VerificationError.mismatch("issue pdf coords / number")
            }

            guard let drawingRow = try Row.fetchOne(
                database,
                sql: "SELECT file_name FROM drawings WHERE id = ?",
                arguments: [drawingId.uuidString]
            ) else {
                throw VerificationError.mismatch("drawing row missing")
            }
            let storedFileName: String = drawingRow["file_name"]
            guard storedFileName == fileName else {
                throw VerificationError.mismatch("drawing file_name")
            }

            guard let calRow = try Row.fetchOne(
                database,
                sql: "SELECT point_a_x, point_a_y, point_b_x, point_b_y FROM page_calibrations WHERE id = ?",
                arguments: [calId.uuidString]
            ) else {
                throw VerificationError.mismatch("calibration row missing")
            }
            let ax: Double = calRow["point_a_x"]
            let ay: Double = calRow["point_a_y"]
            let bx: Double = calRow["point_b_x"]
            let by: Double = calRow["point_b_y"]
            guard ax == 10.5, ay == 20.5, bx == 110.5, by == 20.5 else {
                throw VerificationError.mismatch("calibration PDF points")
            }

            guard let photoRow = try Row.fetchOne(
                database,
                sql: "SELECT file_name FROM issue_photos WHERE id = ?",
                arguments: [photoId.uuidString]
            ) else {
                throw VerificationError.mismatch("issue photo row missing")
            }
            let storedPhotoName: String = photoRow["file_name"]
            guard storedPhotoName == photoName else {
                throw VerificationError.mismatch("issue photo file_name")
            }

            // Recovery copies created; originals retained
            let preProject = projectRoot.appendingPathComponent("appdata-pre-sqlite.json")
            let preUser = root.appendingPathComponent("userdata-pre-sqlite.json")
            guard fm.fileExists(atPath: preProject.path),
                  fm.fileExists(atPath: preUser.path),
                  fm.fileExists(atPath: projectRoot.appendingPathComponent("appdata.json").path)
            else {
                throw VerificationError.mismatch("pre-sqlite recovery copies / originals")
            }
        }

        return Result(
            passed: true,
            message: "Import preserved UUIDs, PDF coords, file paths; second pass skipped; no duplicate rows.",
            firstPassCounts: firstCounts,
            secondPassRowTotals: totals
        )
    }

    private enum VerificationError: LocalizedError {
        case mismatch(String)
        var errorDescription: String? {
            switch self {
            case .mismatch(let detail): return detail
            }
        }
    }

    /// PageCalibration always generates a new id in init; rebuild with a fixed id via JSON.
    private static func forceCalibrationId(_ cal: PageCalibration, id: UUID) throws -> PageCalibration {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var obj = try JSONSerialization.jsonObject(with: encoder.encode(cal)) as? [String: Any] ?? [:]
        obj["id"] = id.uuidString
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PageCalibration.self, from: data)
    }
}
#endif
