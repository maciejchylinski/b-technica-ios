import Foundation
import GRDB

/// Targeted check: create drawing + issue + polygon + photo; edit drawing; reopen;
/// verify related records survive (no CASCADE loss from drawing UPSERT).
enum IssueAreaSQLitePersistenceVerification {
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
            .appendingPathComponent("btechnica-issue-area-sqlite-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let drawingId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let areaId = UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")!
        let issueId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        let photoId = UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111")!
        let fileName = "\(drawingId.uuidString).pdf"
        let photoName = "\(photoId.uuidString).jpg"

        let project = Project(
            id: projectId,
            name: "Cascade Safety Check",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: nil,
            name: "Original Plan",
            fileName: fileName,
            pageCount: 1,
            createdDate: Date(timeIntervalSince1970: 1_700_000_100),
            revision: "A"
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
            createdDate: Date(timeIntervalSince1970: 1_700_000_200),
            updatedDate: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let issue = Issue(
            id: issueId,
            drawingId: drawingId,
            pageIndex: 0,
            pdfX: 100.5,
            pdfY: 200.25,
            areaId: areaId,
            number: 3,
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

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)

        try db.persistProjectWorkspace(
            project: project,
            folders: [],
            drawings: [drawing],
            areas: [area],
            issues: [issue]
        )

        // Edit drawing metadata only — related rows must survive.
        drawing.name = "Edited Plan Name"
        drawing.revision = "B"
        drawing.discipline = "Architectural"
        try db.persistProjectWorkspace(
            project: project,
            folders: [],
            drawings: [drawing],
            areas: [area],
            issues: [issue]
        )

        // Also confirm drawing-only path does not wipe dependents.
        try db.replaceFoldersAndDrawings(
            project: project,
            folders: [],
            drawings: [drawing]
        )

        let reopened = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        let drawings = try reopened.fetchDrawings(projectId: projectId)
        let areas = try reopened.fetchAreas(projectId: projectId)
        let issues = try reopened.fetchIssues(projectId: projectId)

        guard let loadedDrawing = drawings.first(where: { $0.id == drawingId }),
              loadedDrawing.name == "Edited Plan Name",
              loadedDrawing.revision == "B",
              loadedDrawing.fileName == fileName
        else {
            return Result(passed: false, message: "Drawing edit not preserved")
        }

        guard areas.count == 1, let loadedArea = areas.first, loadedArea.id == areaId,
              loadedArea.vertices.count == 3,
              loadedArea.drawingId == drawingId
        else {
            return Result(passed: false, message: "Area lost after drawing edit (CASCADE?)")
        }

        guard issues.count == 1, let loadedIssue = issues.first, loadedIssue.id == issueId,
              loadedIssue.pdfX == 100.5,
              loadedIssue.pdfY == 200.25,
              loadedIssue.number == 3,
              loadedIssue.areaId == areaId,
              loadedIssue.drawingId == drawingId,
              loadedIssue.photos.count == 1,
              loadedIssue.photos[0].id == photoId,
              loadedIssue.photos[0].fileName == photoName
        else {
            return Result(passed: false, message: "Issue/photo lost after drawing edit (CASCADE?)")
        }

        return Result(
            passed: true,
            message: "Drawing edit preserved related issue, polygon, and photo metadata across reopen."
        )
    }
}
