import Foundation
import GRDB

/// Turns free text typed by an engineer into a safe FTS5 MATCH expression.
///
/// - `"quoted text"` → exact phrase.
/// - Plain words → every word must appear (prefix match, so `fundament` finds `fundamentów`);
///   adjacent occurrences rank higher because the whole input is also OR-ed in as a phrase.
/// - Words containing punctuation (`C25/30`, `PN-EN`) become phrases of their parts,
///   mirroring how the `unicode61` tokenizer splits them.
enum KnowledgeQueryParser {
    struct Parsed: Equatable {
        /// Phrases the user quoted explicitly.
        var phrases: [[String]]
        /// Unquoted words, each already split into tokenizer-compatible parts.
        var words: [[String]]
        /// Original words / phrases for in-PDF highlighting.
        var highlightTerms: [String]

        var isEmpty: Bool { phrases.isEmpty && words.isEmpty }
    }

    static func parse(_ raw: String) -> Parsed {
        var phrases: [[String]] = []
        var words: [[String]] = []
        var highlights: [String] = []

        let segments = raw.split(separator: "\"", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            let isQuoted = index % 2 == 1 && index < segments.count - 1
            if isQuoted {
                let tokens = tokenize(String(segment))
                if !tokens.isEmpty {
                    phrases.append(tokens)
                    highlights.append(segment.trimmingCharacters(in: .whitespaces))
                }
            } else {
                for word in segment.split(whereSeparator: { $0.isWhitespace }) {
                    let tokens = tokenize(String(word))
                    guard !tokens.isEmpty else { continue }
                    words.append(tokens)
                    highlights.append(String(word).trimmingCharacters(in: .punctuationCharacters))
                }
            }
        }
        return Parsed(
            phrases: phrases,
            words: words,
            highlightTerms: highlights.filter { !$0.isEmpty }
        )
    }

    /// FTS5 MATCH expression, or nil when the input has no searchable tokens.
    static func matchExpression(for raw: String) -> String? {
        let parsed = parse(raw)
        guard !parsed.isEmpty else { return nil }

        var required: [String] = parsed.phrases.map { "\"\($0.joined(separator: " "))\"" }
        for tokens in parsed.words {
            if tokens.count == 1 {
                required.append("\"\(tokens[0])\"*")
            } else {
                required.append("\"\(tokens.joined(separator: " "))\"")
            }
        }
        let conjunction = required.joined(separator: " AND ")

        if parsed.phrases.isEmpty, parsed.words.count > 1 {
            let wholePhrase = parsed.words.flatMap { $0 }.joined(separator: " ")
            return "\"\(wholePhrase)\" OR (\(conjunction))"
        }
        return conjunction
    }

    /// Lowercased letter/digit runs, matching the `unicode61` tokenizer boundaries.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}

extension AppDatabase {
    /// Full-text search across indexed document pages, document metadata and notes
    /// of exactly one project. Rows from other projects are excluded in SQL.
    func searchKnowledge(
        projectId: UUID,
        query: String,
        scope: KnowledgeSearchScope = .all,
        limit: Int = 100
    ) throws -> [KnowledgeSearchResult] {
        guard let match = KnowledgeQueryParser.matchExpression(for: query) else { return [] }
        let project = projectId.uuidString
        let category = scope.categoryFilter?.rawValue

        return try dbQueue.read { db in
            var results: [KnowledgeSearchResult] = []

            if scope.includesDocuments {
                let pageRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT d.id AS document_id, d.name, d.category, d.revision, d.checksum_sha256,
                           d.file_relative_path, p.page_index,
                           snippet(project_document_page_fts, 0, char(57344), char(57345), '…', 20) AS snippet,
                           bm25(project_document_page_fts) AS rank
                    FROM project_document_page_fts
                    JOIN project_document_pages p ON p.seq = project_document_page_fts.rowid
                    JOIN project_documents d ON d.id = p.document_id
                    WHERE project_document_page_fts MATCH ?
                      AND p.project_id = ? AND d.project_id = ?
                      AND (? IS NULL OR d.category = ?)
                    ORDER BY rank
                    LIMIT ?
                    """,
                    arguments: [match, project, project, category, category, limit]
                )
                for row in pageRows {
                    results.append(Self.documentResult(row: row, projectId: projectId, pageIndex: row["page_index"]))
                }

                let documentRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT d.id AS document_id, d.name, d.category, d.revision, d.checksum_sha256,
                           d.file_relative_path,
                           snippet(project_document_fts, -1, char(57344), char(57345), '…', 16) AS snippet,
                           bm25(project_document_fts, 4.0, 1.0, 1.0, 1.0) AS rank
                    FROM project_document_fts
                    JOIN project_documents d ON d.seq = project_document_fts.rowid
                    WHERE project_document_fts MATCH ?
                      AND d.project_id = ?
                      AND (? IS NULL OR d.category = ?)
                    ORDER BY rank
                    LIMIT ?
                    """,
                    arguments: [match, project, category, category, limit]
                )
                for row in documentRows {
                    var result = Self.documentResult(row: row, projectId: projectId, pageIndex: nil)
                    // Title/metadata hits are strong signals; keep them near the top.
                    result.rank *= 2
                    results.append(result)
                }
            }

            if scope.includesNotes {
                let noteRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT n.id, n.title, n.category,
                           snippet(project_note_fts, 1, char(57344), char(57345), '…', 20) AS body_snippet,
                           snippet(project_note_fts, 0, char(57344), char(57345), '…', 20) AS title_snippet,
                           bm25(project_note_fts, 3.0, 1.0) AS rank
                    FROM project_note_fts
                    JOIN project_notes n ON n.seq = project_note_fts.rowid
                    WHERE project_note_fts MATCH ?
                      AND n.project_id = ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                    arguments: [match, project, limit]
                )
                for row in noteRows {
                    let bodySnippet: String = row["body_snippet"] ?? ""
                    let titleSnippet: String = row["title_snippet"] ?? ""
                    let snippet = bodySnippet.contains(KnowledgeSearchResult.matchStart) ? bodySnippet : titleSnippet
                    let title: String = row["title"] ?? ""
                    results.append(
                        KnowledgeSearchResult(
                            reference: KnowledgeSourceReference(
                                sourceType: .note,
                                projectId: projectId,
                                sourceId: UUID(uuidString: row["id"] ?? "") ?? UUID(),
                                pageIndex: nil,
                                title: title.isEmpty ? "Untitled note" : title,
                                revision: nil,
                                checksumSHA256: nil,
                                fileRelativePath: nil
                            ),
                            snippet: snippet,
                            documentCategory: nil,
                            noteCategory: (row["category"] as String?).flatMap(NoteCategory.init(rawValue:)),
                            rank: row["rank"] ?? 0
                        )
                    )
                }
            }

            return Array(results.sorted { $0.rank < $1.rank }.prefix(limit))
        }
    }

    /// Citation-ready reference for one document page (or the whole document when `pageIndex` is nil).
    func knowledgeSourceReference(documentId: UUID, projectId: UUID, pageIndex: Int?) throws -> KnowledgeSourceReference? {
        guard let document = try fetchProjectDocument(id: documentId, projectId: projectId) else { return nil }
        return KnowledgeSourceReference(
            sourceType: pageIndex == nil ? .document : .documentPage,
            projectId: projectId,
            sourceId: documentId,
            pageIndex: pageIndex,
            title: document.name,
            revision: document.displayRevision,
            checksumSHA256: document.checksumSHA256,
            fileRelativePath: document.fileRelativePath
        )
    }

    private static func documentResult(row: Row, projectId: UUID, pageIndex: Int?) -> KnowledgeSearchResult {
        KnowledgeSearchResult(
            reference: KnowledgeSourceReference(
                sourceType: pageIndex == nil ? .document : .documentPage,
                projectId: projectId,
                sourceId: UUID(uuidString: row["document_id"] ?? "") ?? UUID(),
                pageIndex: pageIndex,
                title: row["name"] ?? "",
                revision: row["revision"],
                checksumSHA256: row["checksum_sha256"],
                fileRelativePath: row["file_relative_path"]
            ),
            snippet: row["snippet"] ?? "",
            documentCategory: DocumentCategory(storedValue: row["category"]),
            noteCategory: nil,
            rank: row["rank"] ?? 0
        )
    }
}
