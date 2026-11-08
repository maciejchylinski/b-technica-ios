// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB

/// Targeted check: store remote page mappings in SQLite, resolve by revision + page_index,
/// reject missing / cross-project / mismatched revision lookups. Isolated temp DB only.
enum DrawingPageMappingVerification {
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
            .appendingPathComponent("btechnica-page-map-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let otherProjectId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let drawingId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let otherDrawingId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let revisionId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")!
        let otherRevisionId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000002")!
        let page0Id = UUID(uuidString: "D0000000-0000-0000-0000-000000000000")!
        let page1Id = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!

        let db = try AppDatabase.open(
            userId: userId,
            at: root.appendingPathComponent("btechnica.sqlite"),
            rootURL: root
        )
        try db.ensureProject(
            Project(id: projectId, name: "Map Check", createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        )
        try db.ensureProject(
            Project(id: otherProjectId, name: "Other", createdDate: Date(timeIntervalSince1970: 1_700_000_001))
        )

        let drawing = Drawing(
            id: drawingId,
            projectId: projectId,
            folderId: nil,
            name: "Multi-page Sheet",
            fileName: "\(drawingId.uuidString).pdf",
            pageCount: 2,
            createdDate: Date(timeIntervalSince1970: 1_700_000_200),
            calibrations: []
        )
        try db.replaceFoldersAndDrawings(project: Project(id: projectId, name: "Map Check", createdDate: Date()), folders: [], drawings: [drawing])

        let pages = [
            RemoteDrawingPage(id: page0Id, revisionId: revisionId, pageIndex: 0),
            RemoteDrawingPage(id: page1Id, revisionId: revisionId, pageIndex: 1)
        ]
        try db.replaceDrawingPageMappings(
            projectId: projectId,
            drawingId: drawingId,
            revisionId: revisionId,
            pages: pages
        )

        // Resolve both pages for a multi-page PDF.
        let resolved0 = try db.resolveDrawingPageId(
            revisionId: revisionId,
            pageIndex: 0,
            projectId: projectId,
            drawingId: drawingId
        )
        let resolved1 = try db.resolveDrawingPageId(
            revisionId: revisionId,
            pageIndex: 1,
            projectId: projectId,
            drawingId: drawingId
        )
        guard resolved0 == page0Id, resolved1 == page1Id else {
            return Result(passed: false, message: "Resolved page ids do not match stored remote ids")
        }

        // Missing mapping must not invent an id.
        do {
            _ = try db.resolveDrawingPageId(revisionId: revisionId, pageIndex: 9)
            return Result(passed: false, message: "Expected missing mapping for page_index 9")
        } catch DrawingPageMappingError.missing(let rev, let index) {
            guard rev == revisionId, index == 9 else {
                return Result(passed: false, message: "Missing error carried wrong keys")
            }
        } catch {
            return Result(passed: false, message: "Wrong error for missing mapping: \(error)")
        }

        // Cross-project ownership rejected.
        do {
            _ = try db.resolveDrawingPageId(
                revisionId: revisionId,
                pageIndex: 0,
                projectId: otherProjectId,
                drawingId: drawingId
            )
            return Result(passed: false, message: "Expected project mismatch rejection")
        } catch DrawingPageMappingError.projectMismatch(_, let expected, _) {
            guard expected == otherProjectId else {
                return Result(passed: false, message: "Project mismatch expected id wrong")
            }
        } catch {
            return Result(passed: false, message: "Wrong error for project mismatch: \(error)")
        }

        // Drawing ownership rejected.
        do {
            _ = try db.resolveDrawingPageId(
                revisionId: revisionId,
                pageIndex: 0,
                projectId: projectId,
                drawingId: otherDrawingId
            )
            return Result(passed: false, message: "Expected drawing mismatch rejection")
        } catch DrawingPageMappingError.drawingMismatch(_, let expected, _) {
            guard expected == otherDrawingId else {
                return Result(passed: false, message: "Drawing mismatch expected id wrong")
            }
        } catch {
            return Result(passed: false, message: "Wrong error for drawing mismatch: \(error)")
        }

        // Wrong revision key has no row (never fall back to another revision).
        do {
            _ = try db.resolveDrawingPageId(revisionId: otherRevisionId, pageIndex: 0)
            return Result(passed: false, message: "Expected missing for other revision")
        } catch DrawingPageMappingError.missing {
            // ok
        } catch {
            return Result(passed: false, message: "Wrong error for other revision: \(error)")
        }

        // Reject cross-revision pages on replace.
        do {
            try db.replaceDrawingPageMappings(
                projectId: projectId,
                drawingId: drawingId,
                revisionId: revisionId,
                pages: [
                    RemoteDrawingPage(id: page0Id, revisionId: otherRevisionId, pageIndex: 0)
                ]
            )
            return Result(passed: false, message: "Expected invalid page rejection on replace")
        } catch DrawingPageMappingError.invalidPage {
            // ok
        } catch {
            return Result(passed: false, message: "Wrong error for invalid page replace: \(error)")
        }

        // Pull path refreshes mappings from remote pages (single-page).
        let singlePageId = UUID(uuidString: "E0000000-0000-0000-0000-000000000010")!
        let singleRevisionId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000010")!
        let remote = RemoteDrawing(
            id: drawingId,
            projectId: projectId,
            folderId: nil,
            name: "Multi-page Sheet",
            discipline: nil,
            location: nil,
            createdAt: drawing.createdDate,
            deletedAt: nil,
            currentRevision: RemoteDrawingRevision(
                id: singleRevisionId,
                drawingId: drawingId,
                revisionLabel: "B",
                storagePath: AppDatabase.drawingPDFRemotePath(projectId: projectId, revisionId: singleRevisionId),
                originalFileName: drawing.fileName,
                pageCount: 1,
                drawingDate: nil,
                isCurrent: true,
                pages: [
                    RemoteDrawingPage(id: singlePageId, revisionId: singleRevisionId, pageIndex: 0)
                ]
            )
        )
        let apply = try db.applyRemoteDrawingPull(projectId: projectId, remoteDrawings: [remote])
        guard apply.upserted == 1 else {
            return Result(passed: false, message: "Pull did not upsert drawing for mapping refresh")
        }
        let afterPull = try db.fetchDrawingPageMappings(drawingId: drawingId)
        guard afterPull.count == 1,
              afterPull[0].drawingPageId == singlePageId,
              afterPull[0].revisionId == singleRevisionId,
              afterPull[0].pageIndex == 0
        else {
            return Result(passed: false, message: "Pull did not refresh page mappings to new revision")
        }
        // Old revision mappings must be gone.
        do {
            _ = try db.resolveDrawingPageId(revisionId: revisionId, pageIndex: 0)
            return Result(passed: false, message: "Stale multi-page revision mapping still present")
        } catch DrawingPageMappingError.missing {
            // ok
        }

        // Drawing UUID / PDF coordinates untouched by mapping store (pins stay on page_index).
        let drawings = try db.fetchDrawings(projectId: projectId)
        guard let kept = drawings.first(where: { $0.id == drawingId }),
              kept.fileName == drawing.fileName,
              kept.pageCount == 1
        else {
            return Result(passed: false, message: "Drawing UUID/file/pageCount not preserved after mapping refresh")
        }

        return Result(
            passed: true,
            message: "Page mappings resolve by revision+index; missing/cross-project rejected; pull refreshes."
        )
    }
}
#endif
