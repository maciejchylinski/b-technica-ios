// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB

/// Targeted check: write drawing metadata to SQLite, reopen, confirm it remains.
/// Uses an isolated temp tree — does not touch live Documents data.
enum DrawingSQLitePersistenceVerification {
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
            .appendingPathComponent("btechnica-drawing-sqlite-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let drawingId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let folderId = UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333")!
        let fileName = "\(drawingId.uuidString).pdf"

        let project = Project(
            id: projectId,
            name: "Persist Check",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let folder = DrawingFolder(
            id: folderId,
            projectId: projectId,
            parentFolderId: nil,
            name: "Plans",
            sortOrder: 0,
            createdDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let original = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: folderId,
            name: "Original Name",
            fileName: fileName,
            pageCount: 2,
            createdDate: Date(timeIntervalSince1970: 1_700_000_200),
            revision: "A",
            discipline: "Arch",
            location: "L1",
            drawingDate: nil,
            calibrations: []
        )

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.replaceFoldersAndDrawings(project: project, folders: [folder], drawings: [original])

        // Simulate edit + "restart" by reopening the same file.
        var edited = original
        edited.name = "Edited After Restart"
        edited.revision = "B"
        try db.replaceFoldersAndDrawings(project: project, folders: [folder], drawings: [edited])

        let reopened = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        let folders = try reopened.fetchDrawingFolders(projectId: projectId)
        let drawings = try reopened.fetchDrawings(projectId: projectId)

        guard folders.count == 1, folders[0].id == folderId, folders[0].name == "Plans" else {
            return Result(passed: false, message: "Folder not preserved after reopen")
        }
        guard let drawing = drawings.first(where: { $0.id == drawingId }) else {
            return Result(passed: false, message: "Drawing UUID missing after reopen")
        }
        guard drawing.name == "Edited After Restart",
              drawing.revision == "B",
              drawing.fileName == fileName,
              drawing.folderId == folderId,
              drawing.pageCount == 2
        else {
            return Result(
                passed: false,
                message: "Drawing edit/path not preserved (name=\(drawing.name), file=\(drawing.fileName))"
            )
        }

        // Ensure a second replace with the same ids does not duplicate.
        try reopened.replaceFoldersAndDrawings(project: project, folders: [folder], drawings: [edited])
        let count: Int = try reopened.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drawings WHERE project_id = ?", arguments: [projectId.uuidString]) ?? -1
        }
        guard count == 1 else {
            return Result(passed: false, message: "Duplicate drawings after second write (count=\(count))")
        }

        return Result(
            passed: true,
            message: "Drawing edit survived reopen; UUID and file_name preserved; no duplicates."
        )
    }
}
#endif
