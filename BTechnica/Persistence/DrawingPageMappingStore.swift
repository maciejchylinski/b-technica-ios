import Foundation
import GRDB

/// One local row mapping a remote `drawing_pages` UUID to revision + page index.
struct DrawingPageMapping: Equatable, Sendable {
    var drawingPageId: UUID
    var projectId: UUID
    var drawingId: UUID
    var revisionId: UUID
    var pageIndex: Int
    var updatedAt: Date
}

enum DrawingPageMappingError: LocalizedError, Equatable {
    case missing(revisionId: UUID, pageIndex: Int)
    case projectMismatch(drawingPageId: UUID, expected: UUID, actual: UUID)
    case drawingMismatch(drawingPageId: UUID, expected: UUID, actual: UUID)
    case revisionMismatch(drawingPageId: UUID, expected: UUID, actual: UUID)
    case invalidPage(RemoteDrawingPage, reason: String)
    case corruptRow

    var errorDescription: String? {
        switch self {
        case .missing(let revisionId, let pageIndex):
            return "No drawing_page mapping for revision \(revisionId) page_index \(pageIndex)"
        case .projectMismatch(let pageId, let expected, let actual):
            return "drawing_page \(pageId) project mismatch expected=\(expected) actual=\(actual)"
        case .drawingMismatch(let pageId, let expected, let actual):
            return "drawing_page \(pageId) drawing mismatch expected=\(expected) actual=\(actual)"
        case .revisionMismatch(let pageId, let expected, let actual):
            return "drawing_page \(pageId) revision mismatch expected=\(expected) actual=\(actual)"
        case .invalidPage(let page, let reason):
            return "Invalid remote page \(page.id): \(reason)"
        case .corruptRow:
            return "Corrupt drawing_page_mappings row"
        }
    }
}

extension AppDatabase {
    /// Replaces all page mappings for `drawingId` with the pages of one revision.
    /// Rejects pages whose `revisionId` does not match, or negative indexes.
    /// Does not invent page ids — every stored id must come from `pages`.
    func replaceDrawingPageMappings(
        projectId: UUID,
        drawingId: UUID,
        revisionId: UUID,
        pages: [RemoteDrawingPage],
        now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try Self.replaceDrawingPageMappings(
                projectId: projectId,
                drawingId: drawingId,
                revisionId: revisionId,
                pages: pages,
                now: now,
                db: db
            )
        }
    }

    /// Resolves remote `drawing_pages.id` for a revision UUID + 0-based page index.
    /// Never guesses: missing rows throw `.missing`.
    /// When `projectId` / `drawingId` are provided, mismatched ownership is rejected.
    func resolveDrawingPageId(
        revisionId: UUID,
        pageIndex: Int,
        projectId: UUID? = nil,
        drawingId: UUID? = nil
    ) throws -> UUID {
        try dbQueue.read { db in
            try Self.resolveDrawingPageId(
                revisionId: revisionId,
                pageIndex: pageIndex,
                projectId: projectId,
                drawingId: drawingId,
                db: db
            )
        }
    }

    /// All mappings for a drawing (ordered by revision then page index).
    func fetchDrawingPageMappings(drawingId: UUID) throws -> [DrawingPageMapping] {
        try dbQueue.read { db in
            try Self.fetchDrawingPageMappings(drawingId: drawingId, db: db)
        }
    }

    /// All mappings for one revision (ordered by page index).
    func fetchDrawingPageMappings(revisionId: UUID) throws -> [DrawingPageMapping] {
        try dbQueue.read { db in
            try Self.fetchDrawingPageMappings(revisionId: revisionId, db: db)
        }
    }

    // MARK: - Internals

    static func replaceDrawingPageMappings(
        projectId: UUID,
        drawingId: UUID,
        revisionId: UUID,
        pages: [RemoteDrawingPage],
        now: Date,
        db: Database
    ) throws {
        for page in pages {
            guard page.revisionId == revisionId else {
                throw DrawingPageMappingError.invalidPage(
                    page,
                    reason: "revision_id \(page.revisionId) != expected \(revisionId)"
                )
            }
            guard page.pageIndex >= 0 else {
                throw DrawingPageMappingError.invalidPage(
                    page,
                    reason: "negative page_index \(page.pageIndex)"
                )
            }
        }

        // Drop any prior revision mappings for this drawing (current revision wins).
        try db.execute(
            sql: "DELETE FROM drawing_page_mappings WHERE drawing_id = ?",
            arguments: [drawingId.uuidString]
        )

        let stamp = SQLiteDateCoding.string(from: now)
        for page in pages {
            try db.execute(
                sql: """
                INSERT INTO drawing_page_mappings
                  (drawing_page_id, project_id, drawing_id, revision_id, page_index, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    page.id.uuidString,
                    projectId.uuidString,
                    drawingId.uuidString,
                    revisionId.uuidString,
                    page.pageIndex,
                    stamp
                ]
            )
        }
    }

    static func resolveDrawingPageId(
        revisionId: UUID,
        pageIndex: Int,
        projectId: UUID?,
        drawingId: UUID?,
        db: Database
    ) throws -> UUID {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT drawing_page_id, project_id, drawing_id, revision_id, page_index
            FROM drawing_page_mappings
            WHERE revision_id = ? AND page_index = ?
            """,
            arguments: [revisionId.uuidString, pageIndex]
        ) else {
            throw DrawingPageMappingError.missing(revisionId: revisionId, pageIndex: pageIndex)
        }

        let pageIdRaw: String = row["drawing_page_id"]
        guard let pageId = UUID(uuidString: pageIdRaw) else {
            throw DrawingPageMappingError.missing(revisionId: revisionId, pageIndex: pageIndex)
        }

        let storedRevisionRaw: String = row["revision_id"]
        guard let storedRevision = UUID(uuidString: storedRevisionRaw),
              storedRevision == revisionId
        else {
            throw DrawingPageMappingError.revisionMismatch(
                drawingPageId: pageId,
                expected: revisionId,
                actual: UUID(uuidString: storedRevisionRaw) ?? UUID()
            )
        }

        if let projectId {
            let storedProjectRaw: String = row["project_id"]
            guard let storedProject = UUID(uuidString: storedProjectRaw),
                  storedProject == projectId
            else {
                throw DrawingPageMappingError.projectMismatch(
                    drawingPageId: pageId,
                    expected: projectId,
                    actual: UUID(uuidString: storedProjectRaw) ?? UUID()
                )
            }
        }

        if let drawingId {
            let storedDrawingRaw: String = row["drawing_id"]
            guard let storedDrawing = UUID(uuidString: storedDrawingRaw),
                  storedDrawing == drawingId
            else {
                throw DrawingPageMappingError.drawingMismatch(
                    drawingPageId: pageId,
                    expected: drawingId,
                    actual: UUID(uuidString: storedDrawingRaw) ?? UUID()
                )
            }
        }

        return pageId
    }

    static func fetchDrawingPageMappings(drawingId: UUID, db: Database) throws -> [DrawingPageMapping] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT drawing_page_id, project_id, drawing_id, revision_id, page_index, updated_at
            FROM drawing_page_mappings
            WHERE drawing_id = ?
            ORDER BY revision_id ASC, page_index ASC
            """,
            arguments: [drawingId.uuidString]
        )
        return try rows.map(Self.mapping(from:))
    }

    static func fetchDrawingPageMappings(revisionId: UUID, db: Database) throws -> [DrawingPageMapping] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT drawing_page_id, project_id, drawing_id, revision_id, page_index, updated_at
            FROM drawing_page_mappings
            WHERE revision_id = ?
            ORDER BY page_index ASC
            """,
            arguments: [revisionId.uuidString]
        )
        return try rows.map(Self.mapping(from:))
    }

    static func deleteDrawingPageMappings(drawingId: UUID, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM drawing_page_mappings WHERE drawing_id = ?",
            arguments: [drawingId.uuidString]
        )
    }

    private static func mapping(from row: Row) throws -> DrawingPageMapping {
        let pageRaw: String = row["drawing_page_id"]
        let projectRaw: String = row["project_id"]
        let drawingRaw: String = row["drawing_id"]
        let revisionRaw: String = row["revision_id"]
        let updatedRaw: String = row["updated_at"]
        guard let pageId = UUID(uuidString: pageRaw),
              let projectId = UUID(uuidString: projectRaw),
              let drawingId = UUID(uuidString: drawingRaw),
              let revisionId = UUID(uuidString: revisionRaw),
              let updatedAt = SQLiteDateCoding.date(from: updatedRaw)
        else {
            throw DrawingPageMappingError.corruptRow
        }
        let pageIndex: Int = row["page_index"]
        return DrawingPageMapping(
            drawingPageId: pageId,
            projectId: projectId,
            drawingId: drawingId,
            revisionId: revisionId,
            pageIndex: pageIndex,
            updatedAt: updatedAt
        )
    }
}
