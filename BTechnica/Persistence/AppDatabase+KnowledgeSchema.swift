import Foundation
import GRDB

extension AppDatabase {
    /// Project document library, extracted page text, field notes and their FTS5 indexes.
    ///
    /// Search tables are FTS5 *external content* tables kept in sync by triggers.
    /// Content tables use an explicit `seq INTEGER PRIMARY KEY` so FTS rowids stay
    /// stable across `VACUUM` (implicit rowids of TEXT-keyed tables may be renumbered).
    static func createProjectKnowledgeSchema(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE project_document_folders (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            parent_folder_id TEXT REFERENCES project_document_folders(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK (parent_folder_id IS NULL OR parent_folder_id <> id)
        );
        CREATE INDEX project_document_folders_project_id ON project_document_folders(project_id);
        CREATE INDEX project_document_folders_parent_id ON project_document_folders(parent_folder_id);

        CREATE TABLE project_documents (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            folder_id TEXT REFERENCES project_document_folders(id) ON DELETE SET NULL,
            name TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT 'other',
            description TEXT NOT NULL DEFAULT '',
            original_file_name TEXT NOT NULL,
            file_relative_path TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            checksum_sha256 TEXT,
            revision TEXT,
            revision_date TEXT,
            uploaded_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            index_status TEXT NOT NULL DEFAULT 'pending',
            index_error TEXT,
            index_attempts INTEGER NOT NULL DEFAULT 0,
            index_started_at TEXT,
            indexed_at TEXT,
            indexed_checksum TEXT,
            extractor_version INTEGER,
            extraction_method TEXT,
            text_page_count INTEGER NOT NULL DEFAULT 0,
            ocr_page_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX project_documents_project_id ON project_documents(project_id);
        CREATE INDEX project_documents_folder_id ON project_documents(folder_id);
        CREATE INDEX project_documents_index_status ON project_documents(project_id, index_status);
        CREATE INDEX project_documents_checksum ON project_documents(project_id, checksum_sha256);

        CREATE TABLE project_document_pages (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id TEXT NOT NULL REFERENCES project_documents(id) ON DELETE CASCADE,
            project_id TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            page_label TEXT,
            text TEXT NOT NULL DEFAULT '',
            extraction_method TEXT NOT NULL,
            ocr_confidence REAL,
            char_count INTEGER NOT NULL DEFAULT 0,
            extracted_at TEXT NOT NULL,
            UNIQUE (document_id, page_index)
        );
        CREATE INDEX project_document_pages_project_id ON project_document_pages(project_id);

        CREATE TABLE project_notes (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            body TEXT NOT NULL DEFAULT '',
            category TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX project_notes_project_id ON project_notes(project_id, updated_at);

        -- Full-text search (diacritic-insensitive: "odpornosc" matches "odporność").

        CREATE VIRTUAL TABLE project_document_page_fts USING fts5(
            text,
            content='project_document_pages', content_rowid='seq',
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER project_document_pages_fts_ai AFTER INSERT ON project_document_pages BEGIN
            INSERT INTO project_document_page_fts(rowid, text) VALUES (new.seq, new.text);
        END;
        CREATE TRIGGER project_document_pages_fts_ad AFTER DELETE ON project_document_pages BEGIN
            INSERT INTO project_document_page_fts(project_document_page_fts, rowid, text)
            VALUES ('delete', old.seq, old.text);
        END;
        CREATE TRIGGER project_document_pages_fts_au AFTER UPDATE OF text ON project_document_pages BEGIN
            INSERT INTO project_document_page_fts(project_document_page_fts, rowid, text)
            VALUES ('delete', old.seq, old.text);
            INSERT INTO project_document_page_fts(rowid, text) VALUES (new.seq, new.text);
        END;

        CREATE VIRTUAL TABLE project_document_fts USING fts5(
            name, description, original_file_name, revision,
            content='project_documents', content_rowid='seq',
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER project_documents_fts_ai AFTER INSERT ON project_documents BEGIN
            INSERT INTO project_document_fts(rowid, name, description, original_file_name, revision)
            VALUES (new.seq, new.name, new.description, new.original_file_name, new.revision);
        END;
        CREATE TRIGGER project_documents_fts_ad AFTER DELETE ON project_documents BEGIN
            INSERT INTO project_document_fts(project_document_fts, rowid, name, description, original_file_name, revision)
            VALUES ('delete', old.seq, old.name, old.description, old.original_file_name, old.revision);
        END;
        CREATE TRIGGER project_documents_fts_au
        AFTER UPDATE OF name, description, original_file_name, revision ON project_documents BEGIN
            INSERT INTO project_document_fts(project_document_fts, rowid, name, description, original_file_name, revision)
            VALUES ('delete', old.seq, old.name, old.description, old.original_file_name, old.revision);
            INSERT INTO project_document_fts(rowid, name, description, original_file_name, revision)
            VALUES (new.seq, new.name, new.description, new.original_file_name, new.revision);
        END;

        CREATE VIRTUAL TABLE project_note_fts USING fts5(
            title, body,
            content='project_notes', content_rowid='seq',
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER project_notes_fts_ai AFTER INSERT ON project_notes BEGIN
            INSERT INTO project_note_fts(rowid, title, body) VALUES (new.seq, new.title, new.body);
        END;
        CREATE TRIGGER project_notes_fts_ad AFTER DELETE ON project_notes BEGIN
            INSERT INTO project_note_fts(project_note_fts, rowid, title, body)
            VALUES ('delete', old.seq, old.title, old.body);
        END;
        CREATE TRIGGER project_notes_fts_au AFTER UPDATE OF title, body ON project_notes BEGIN
            INSERT INTO project_note_fts(project_note_fts, rowid, title, body)
            VALUES ('delete', old.seq, old.title, old.body);
            INSERT INTO project_note_fts(rowid, title, body) VALUES (new.seq, new.title, new.body);
        END;
        """)
    }
}
