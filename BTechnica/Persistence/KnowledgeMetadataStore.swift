import Foundation
import GRDB

/// SQLite read/write for the project document library, extracted page text and field notes.
/// Every query is scoped by `project_id`; PDF bytes stay on disk under `ProjectDocuments/`.
extension AppDatabase {
    enum KnowledgeError: LocalizedError {
        case notFound
        case invalidName
        case duplicateName
        case invalidMove

        var errorDescription: String? {
            switch self {
            case .notFound: return "The item no longer exists."
            case .invalidName: return "Enter a name."
            case .duplicateName: return "An item with this name already exists here."
            case .invalidMove: return "A folder cannot be moved into itself or one of its subfolders."
            }
        }
    }

    // MARK: Folders

    func fetchDocumentFolders(projectId: UUID) throws -> [ProjectDocumentFolder] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM project_document_folders
                WHERE project_id = ?
                ORDER BY sort_order ASC, name COLLATE NOCASE ASC
                """,
                arguments: [projectId.uuidString]
            ).map(Self.documentFolder(from:))
        }
    }

    func insertDocumentFolder(_ folder: ProjectDocumentFolder) throws {
        try dbQueue.write { db in
            try Self.requireUniqueFolderName(
                folder.name, projectId: folder.projectId, parentId: folder.parentFolderId,
                excluding: nil, db: db
            )
            if let parentId = folder.parentFolderId {
                try Self.requireFolder(parentId, projectId: folder.projectId, db: db)
            }
            try db.execute(
                sql: """
                INSERT INTO project_document_folders
                    (id, project_id, parent_folder_id, name, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    folder.id.uuidString, folder.projectId.uuidString, folder.parentFolderId?.uuidString,
                    folder.name, folder.sortOrder,
                    SQLiteDateCoding.string(from: folder.createdAt),
                    SQLiteDateCoding.string(from: folder.updatedAt)
                ]
            )
        }
    }

    func renameDocumentFolder(id: UUID, projectId: UUID, name: String) throws {
        try dbQueue.write { db in
            let folder = try Self.requireFolder(id, projectId: projectId, db: db)
            try Self.requireUniqueFolderName(
                name, projectId: projectId, parentId: folder.parentFolderId, excluding: id, db: db
            )
            try db.execute(
                sql: "UPDATE project_document_folders SET name = ?, updated_at = ? WHERE id = ? AND project_id = ?",
                arguments: [name, SQLiteDateCoding.string(from: Date()), id.uuidString, projectId.uuidString]
            )
        }
    }

    func moveDocumentFolder(id: UUID, projectId: UUID, toParentId: UUID?) throws {
        try dbQueue.write { db in
            let folder = try Self.requireFolder(id, projectId: projectId, db: db)
            if let toParentId {
                try Self.requireFolder(toParentId, projectId: projectId, db: db)
                let descendants = try Self.descendantFolderIds(of: id, db: db)
                if toParentId == id || descendants.contains(toParentId) {
                    throw KnowledgeError.invalidMove
                }
            }
            try Self.requireUniqueFolderName(
                folder.name, projectId: projectId, parentId: toParentId, excluding: id, db: db
            )
            try db.execute(
                sql: """
                UPDATE project_document_folders SET parent_folder_id = ?, updated_at = ?
                WHERE id = ? AND project_id = ?
                """,
                arguments: [toParentId?.uuidString, SQLiteDateCoding.string(from: Date()),
                            id.uuidString, projectId.uuidString]
            )
        }
    }

    /// Deletes a folder, its subfolders and every document inside them.
    /// Returns the deleted documents so the caller can remove their files.
    func deleteDocumentFolder(id: UUID, projectId: UUID) throws -> [ProjectDocument] {
        try dbQueue.write { db in
            try Self.requireFolder(id, projectId: projectId, db: db)
            let folderIds = [id] + (try Self.descendantFolderIds(of: id, db: db))
            let placeholders = Array(repeating: "?", count: folderIds.count).joined(separator: ",")
            var arguments: [DatabaseValueConvertible?] = [projectId.uuidString]
            arguments.append(contentsOf: folderIds.map(\.uuidString))
            let documents = try Row.fetchAll(
                db,
                sql: "SELECT * FROM project_documents WHERE project_id = ? AND folder_id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            ).map(Self.document(from:))
            try db.execute(
                sql: "DELETE FROM project_documents WHERE project_id = ? AND folder_id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
            try db.execute(
                sql: "DELETE FROM project_document_folders WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
            return documents
        }
    }

    // MARK: Documents

    func fetchProjectDocuments(projectId: UUID) throws -> [ProjectDocument] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM project_documents
                WHERE project_id = ?
                ORDER BY name COLLATE NOCASE ASC, uploaded_at ASC
                """,
                arguments: [projectId.uuidString]
            ).map(Self.document(from:))
        }
    }

    func fetchProjectDocument(id: UUID, projectId: UUID) throws -> ProjectDocument? {
        try dbQueue.read { db in
            try Self.fetchDocumentRow(id: id, projectId: projectId, db: db)
        }
    }

    func fetchProjectDocument(projectId: UUID, checksum: String) throws -> ProjectDocument? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM project_documents WHERE project_id = ? AND checksum_sha256 = ? LIMIT 1",
                arguments: [projectId.uuidString, checksum]
            ).map(Self.document(from:))
        }
    }

    func insertProjectDocument(_ document: ProjectDocument) throws {
        try dbQueue.write { db in
            if let folderId = document.folderId {
                try Self.requireFolder(folderId, projectId: document.projectId, db: db)
            }
            try db.execute(
                sql: """
                INSERT INTO project_documents (
                    id, project_id, folder_id, name, category, description, original_file_name,
                    file_relative_path, file_size_bytes, page_count, checksum_sha256, revision,
                    revision_date, uploaded_at, updated_at, index_status, index_error, index_attempts
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    document.id.uuidString, document.projectId.uuidString, document.folderId?.uuidString,
                    document.name, document.category.rawValue, document.descriptionText,
                    document.originalFileName, document.fileRelativePath, document.fileSizeBytes,
                    document.pageCount, document.checksumSHA256, document.revision,
                    document.revisionDate.map(SQLiteDateCoding.string(from:)),
                    SQLiteDateCoding.string(from: document.uploadedAt),
                    SQLiteDateCoding.string(from: document.updatedAt),
                    document.indexStatus.rawValue, document.indexError, document.indexAttempts
                ]
            )
        }
    }

    /// Updates user-editable metadata (never touches file or index columns).
    func updateProjectDocumentMetadata(
        id: UUID,
        projectId: UUID,
        name: String,
        category: DocumentCategory,
        descriptionText: String,
        revision: String?,
        revisionDate: Date?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE project_documents
                SET name = ?, category = ?, description = ?, revision = ?, revision_date = ?, updated_at = ?
                WHERE id = ? AND project_id = ?
                """,
                arguments: [
                    name, category.rawValue, descriptionText, revision,
                    revisionDate.map(SQLiteDateCoding.string(from:)),
                    SQLiteDateCoding.string(from: Date()),
                    id.uuidString, projectId.uuidString
                ]
            )
            if db.changesCount == 0 { throw KnowledgeError.notFound }
        }
    }

    func moveProjectDocument(id: UUID, projectId: UUID, toFolderId: UUID?) throws {
        try dbQueue.write { db in
            if let toFolderId {
                try Self.requireFolder(toFolderId, projectId: projectId, db: db)
            }
            try db.execute(
                sql: "UPDATE project_documents SET folder_id = ?, updated_at = ? WHERE id = ? AND project_id = ?",
                arguments: [toFolderId?.uuidString, SQLiteDateCoding.string(from: Date()),
                            id.uuidString, projectId.uuidString]
            )
            if db.changesCount == 0 { throw KnowledgeError.notFound }
        }
    }

    /// Deletes the row (pages and FTS entries cascade). Returns the deleted document.
    @discardableResult
    func deleteProjectDocument(id: UUID, projectId: UUID) throws -> ProjectDocument? {
        try dbQueue.write { db in
            let existing = try Self.fetchDocumentRow(id: id, projectId: projectId, db: db)
            try db.execute(
                sql: "DELETE FROM project_documents WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
            return existing
        }
    }

    // MARK: Indexing state

    /// Documents that need (re)indexing for the current extractor version, oldest first.
    func fetchDocumentsNeedingIndex(projectId: UUID, extractorVersion: Int) throws -> [ProjectDocument] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM project_documents
                WHERE project_id = ?
                  AND (index_status = 'pending'
                       OR (index_status = 'indexed' AND COALESCE(extractor_version, 0) < ?))
                ORDER BY uploaded_at ASC
                """,
                arguments: [projectId.uuidString, extractorVersion]
            ).map(Self.document(from:))
        }
    }

    /// Indexing that was interrupted (app killed) goes back to the queue.
    func resetInterruptedIndexing(projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project_documents SET index_status = 'pending' WHERE project_id = ? AND index_status = 'indexing'",
                arguments: [projectId.uuidString]
            )
        }
    }

    /// Queues a document for indexing. `force` also discards the "unchanged" marker.
    func requestDocumentIndexing(id: UUID, projectId: UUID, force: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE project_documents
                SET index_status = 'pending', index_error = NULL,
                    indexed_checksum = CASE WHEN ? THEN NULL ELSE indexed_checksum END
                WHERE id = ? AND project_id = ?
                """,
                arguments: [force, id.uuidString, projectId.uuidString]
            )
        }
    }

    func markDocumentIndexing(id: UUID, checksum: String?, fileSizeBytes: Int64?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE project_documents
                SET index_status = 'indexing', index_error = NULL, index_started_at = ?,
                    index_attempts = index_attempts + 1,
                    checksum_sha256 = COALESCE(?, checksum_sha256),
                    file_size_bytes = COALESCE(?, file_size_bytes)
                WHERE id = ?
                """,
                arguments: [SQLiteDateCoding.string(from: Date()), checksum, fileSizeBytes, id.uuidString]
            )
        }
    }

    func markDocumentIndexFailed(id: UUID, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project_documents SET index_status = 'failed', index_error = ? WHERE id = ?",
                arguments: [error, id.uuidString]
            )
        }
    }

    /// Marks a document as indexed without re-extracting (file unchanged since last index).
    func markDocumentIndexUnchanged(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project_documents SET index_status = 'indexed', index_error = NULL WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func deleteDocumentPages(documentId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM project_document_pages WHERE document_id = ?",
                arguments: [documentId.uuidString]
            )
        }
    }

    func upsertDocumentPage(_ page: ProjectDocumentPage) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO project_document_pages
                    (document_id, project_id, page_index, page_label, text, extraction_method,
                     ocr_confidence, char_count, extracted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id, page_index) DO UPDATE SET
                    page_label = excluded.page_label,
                    text = excluded.text,
                    extraction_method = excluded.extraction_method,
                    ocr_confidence = excluded.ocr_confidence,
                    char_count = excluded.char_count,
                    extracted_at = excluded.extracted_at
                """,
                arguments: [
                    page.documentId.uuidString, page.projectId.uuidString, page.pageIndex, page.pageLabel,
                    page.text, page.extractionMethod.rawValue, page.ocrConfidence, page.text.count,
                    SQLiteDateCoding.string(from: page.extractedAt)
                ]
            )
        }
    }

    func markDocumentIndexed(
        id: UUID,
        checksum: String?,
        extractorVersion: Int,
        pageCount: Int,
        summary: DocumentExtractionSummary,
        textPageCount: Int,
        ocrPageCount: Int
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE project_documents
                SET index_status = 'indexed', index_error = NULL, indexed_at = ?, indexed_checksum = ?,
                    extractor_version = ?, page_count = ?, extraction_method = ?,
                    text_page_count = ?, ocr_page_count = ?
                WHERE id = ?
                """,
                arguments: [
                    SQLiteDateCoding.string(from: Date()), checksum, extractorVersion, pageCount,
                    summary.rawValue, textPageCount, ocrPageCount, id.uuidString
                ]
            )
        }
    }

    // MARK: Pages (citation source for future assistant)

    func fetchDocumentPages(documentId: UUID, projectId: UUID) throws -> [ProjectDocumentPage] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM project_document_pages
                WHERE document_id = ? AND project_id = ?
                ORDER BY page_index ASC
                """,
                arguments: [documentId.uuidString, projectId.uuidString]
            ).map(Self.documentPage(from:))
        }
    }

    func fetchDocumentPage(documentId: UUID, projectId: UUID, pageIndex: Int) throws -> ProjectDocumentPage? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM project_document_pages
                WHERE document_id = ? AND project_id = ? AND page_index = ?
                """,
                arguments: [documentId.uuidString, projectId.uuidString, pageIndex]
            ).map(Self.documentPage(from:))
        }
    }

    // MARK: Notes

    func fetchProjectNotes(projectId: UUID) throws -> [ProjectNote] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM project_notes WHERE project_id = ? ORDER BY updated_at DESC",
                arguments: [projectId.uuidString]
            ).map(Self.note(from:))
        }
    }

    func upsertProjectNote(_ note: ProjectNote) throws {
        try dbQueue.write { db in
            let owner = try String.fetchOne(
                db,
                sql: "SELECT project_id FROM project_notes WHERE id = ?",
                arguments: [note.id.uuidString]
            )
            if let owner, owner != note.projectId.uuidString { throw KnowledgeError.notFound }
            try db.execute(
                sql: """
                INSERT INTO project_notes (id, project_id, title, body, category, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    body = excluded.body,
                    category = excluded.category,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    note.id.uuidString, note.projectId.uuidString, note.title, note.body,
                    note.category?.rawValue,
                    SQLiteDateCoding.string(from: note.createdAt),
                    SQLiteDateCoding.string(from: note.updatedAt)
                ]
            )
        }
    }

    func deleteProjectNote(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM project_notes WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    // MARK: Row mapping

    private static func fetchDocumentRow(id: UUID, projectId: UUID, db: Database) throws -> ProjectDocument? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM project_documents WHERE id = ? AND project_id = ?",
            arguments: [id.uuidString, projectId.uuidString]
        ).map(document(from:))
    }

    @discardableResult
    private static func requireFolder(_ id: UUID, projectId: UUID, db: Database) throws -> ProjectDocumentFolder {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM project_document_folders WHERE id = ? AND project_id = ?",
            arguments: [id.uuidString, projectId.uuidString]
        ) else {
            throw KnowledgeError.notFound
        }
        return documentFolder(from: row)
    }

    private static func requireUniqueFolderName(
        _ name: String,
        projectId: UUID,
        parentId: UUID?,
        excluding: UUID?,
        db: Database
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KnowledgeError.invalidName }
        let clash = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM project_document_folders
                WHERE project_id = ?
                  AND parent_folder_id IS ?
                  AND lower(name) = lower(?)
                  AND id IS NOT ?
            )
            """,
            arguments: [projectId.uuidString, parentId?.uuidString, trimmed, excluding?.uuidString]
        ) ?? false
        if clash { throw KnowledgeError.duplicateName }
    }

    private static func descendantFolderIds(of id: UUID, db: Database) throws -> [UUID] {
        try String.fetchAll(
            db,
            sql: """
            WITH RECURSIVE tree(id) AS (
                SELECT id FROM project_document_folders WHERE parent_folder_id = ?
                UNION ALL
                SELECT f.id FROM project_document_folders f JOIN tree ON f.parent_folder_id = tree.id
            )
            SELECT id FROM tree
            """,
            arguments: [id.uuidString]
        ).compactMap(UUID.init(uuidString:))
    }

    private static func uuid(_ row: Row, _ column: String) -> UUID {
        UUID(uuidString: row[column] ?? "") ?? UUID()
    }

    private static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
        (row[column] as String?).flatMap(UUID.init(uuidString:))
    }

    private static func date(_ row: Row, _ column: String) -> Date {
        optionalDate(row, column) ?? Date(timeIntervalSince1970: 0)
    }

    private static func optionalDate(_ row: Row, _ column: String) -> Date? {
        (row[column] as String?).flatMap(SQLiteDateCoding.date(from:))
    }

    static func documentFolder(from row: Row) -> ProjectDocumentFolder {
        ProjectDocumentFolder(
            id: uuid(row, "id"),
            projectId: uuid(row, "project_id"),
            parentFolderId: optionalUUID(row, "parent_folder_id"),
            name: row["name"] ?? "",
            sortOrder: row["sort_order"] ?? 0,
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }

    static func document(from row: Row) -> ProjectDocument {
        ProjectDocument(
            id: uuid(row, "id"),
            projectId: uuid(row, "project_id"),
            folderId: optionalUUID(row, "folder_id"),
            name: row["name"] ?? "",
            category: DocumentCategory(storedValue: row["category"]),
            descriptionText: row["description"] ?? "",
            originalFileName: row["original_file_name"] ?? "",
            fileRelativePath: row["file_relative_path"] ?? "",
            fileSizeBytes: row["file_size_bytes"] ?? 0,
            pageCount: row["page_count"] ?? 0,
            checksumSHA256: row["checksum_sha256"],
            revision: row["revision"],
            revisionDate: optionalDate(row, "revision_date"),
            uploadedAt: date(row, "uploaded_at"),
            updatedAt: date(row, "updated_at"),
            indexStatus: DocumentIndexStatus(rawValue: row["index_status"] ?? "") ?? .pending,
            indexError: row["index_error"],
            indexAttempts: row["index_attempts"] ?? 0,
            indexStartedAt: optionalDate(row, "index_started_at"),
            indexedAt: optionalDate(row, "indexed_at"),
            indexedChecksum: row["indexed_checksum"],
            extractorVersion: row["extractor_version"],
            extractionSummary: (row["extraction_method"] as String?).flatMap(DocumentExtractionSummary.init(rawValue:)),
            textPageCount: row["text_page_count"] ?? 0,
            ocrPageCount: row["ocr_page_count"] ?? 0
        )
    }

    static func documentPage(from row: Row) -> ProjectDocumentPage {
        ProjectDocumentPage(
            documentId: uuid(row, "document_id"),
            projectId: uuid(row, "project_id"),
            pageIndex: row["page_index"] ?? 0,
            pageLabel: row["page_label"],
            text: row["text"] ?? "",
            extractionMethod: PageExtractionMethod(rawValue: row["extraction_method"] ?? "") ?? .noText,
            ocrConfidence: row["ocr_confidence"],
            extractedAt: date(row, "extracted_at")
        )
    }

    static func note(from row: Row) -> ProjectNote {
        ProjectNote(
            id: uuid(row, "id"),
            projectId: uuid(row, "project_id"),
            title: row["title"] ?? "",
            body: row["body"] ?? "",
            category: (row["category"] as String?).flatMap(NoteCategory.init(rawValue:)),
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }
}
