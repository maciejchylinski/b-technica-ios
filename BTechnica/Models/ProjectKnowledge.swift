import Foundation

/// Kind of project document. Raw values are persisted in SQLite and mirrored in Supabase.
enum DocumentCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case technicalSpecification = "technical_specification"
    case constructionDocumentation = "construction_documentation"
    case materialSpecification = "material_specification"
    case installationManual = "installation_manual"
    case technicalApproval = "technical_approval"
    case constructionInstruction = "construction_instruction"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .technicalSpecification: return "Technical specification"
        case .constructionDocumentation: return "Construction documentation"
        case .materialSpecification: return "Material specification"
        case .installationManual: return "Installation manual"
        case .technicalApproval: return "Technical approval"
        case .constructionInstruction: return "Construction instruction"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .technicalSpecification: return "doc.text.magnifyingglass"
        case .constructionDocumentation: return "building.2"
        case .materialSpecification: return "cube.box"
        case .installationManual: return "wrench.and.screwdriver"
        case .technicalApproval: return "checkmark.seal"
        case .constructionInstruction: return "list.bullet.clipboard"
        case .other: return "doc"
        }
    }

    init(storedValue: String?) {
        self = storedValue.flatMap(DocumentCategory.init(rawValue:)) ?? .other
    }
}

/// Optional classification for field notes.
enum NoteCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case inspection
    case meeting
    case measurement
    case defect
    case instruction
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspection: return "Inspection"
        case .meeting: return "Meeting"
        case .measurement: return "Measurement"
        case .defect: return "Defect"
        case .instruction: return "Instruction"
        case .other: return "Other"
        }
    }
}

enum DocumentIndexStatus: String, Codable, Sendable {
    case pending
    case indexing
    case indexed
    case failed

    var title: String {
        switch self {
        case .pending: return "Waiting to index"
        case .indexing: return "Indexing…"
        case .indexed: return "Indexed"
        case .failed: return "Indexing failed"
        }
    }
}

/// How the text of one page was obtained.
enum PageExtractionMethod: String, Codable, Sendable {
    /// Selectable text layer read through PDFKit.
    case pdfText = "pdf_text"
    /// Apple Vision OCR of the rendered page.
    case ocr
    /// No text could be obtained (blank page, OCR unavailable or empty).
    case noText = "none"
}

/// Document-level summary of the per-page extraction methods.
enum DocumentExtractionSummary: String, Codable, Sendable {
    case pdfText = "pdf_text"
    case ocr
    case mixed
    case noText = "none"

    var title: String {
        switch self {
        case .pdfText: return "PDF text layer"
        case .ocr: return "OCR (scanned)"
        case .mixed: return "PDF text + OCR"
        case .noText: return "No text found"
        }
    }
}

struct ProjectDocumentFolder: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var projectId: UUID
    var parentFolderId: UUID?
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

/// A project document (PDF) stored on device. Stable `id` is the citation anchor
/// for search results and any future assistant.
struct ProjectDocument: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var projectId: UUID
    var folderId: UUID?
    var name: String
    var category: DocumentCategory
    var descriptionText: String
    var originalFileName: String
    /// Path relative to the project root, e.g. `ProjectDocuments/<uuid>.pdf`.
    var fileRelativePath: String
    var fileSizeBytes: Int64
    var pageCount: Int
    var checksumSHA256: String?
    var revision: String?
    var revisionDate: Date?
    var uploadedAt: Date
    var updatedAt: Date

    var indexStatus: DocumentIndexStatus
    var indexError: String?
    var indexAttempts: Int
    var indexStartedAt: Date?
    var indexedAt: Date?
    var indexedChecksum: String?
    var extractorVersion: Int?
    var extractionSummary: DocumentExtractionSummary?
    var textPageCount: Int
    var ocrPageCount: Int

    var displayRevision: String? {
        guard let revision, !revision.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return revision
    }
}

/// Extracted text of one PDF page (0-based `pageIndex`).
struct ProjectDocumentPage: Equatable, Sendable {
    var documentId: UUID
    var projectId: UUID
    var pageIndex: Int
    var pageLabel: String?
    var text: String
    var extractionMethod: PageExtractionMethod
    var ocrConfidence: Double?
    var extractedAt: Date

    var pageNumber: Int { pageIndex + 1 }
}

struct ProjectNote: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var projectId: UUID
    var title: String
    var body: String
    var category: NoteCategory?
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }
}

/// Exact provenance of a piece of knowledge, suitable for citing "document X, page N".
struct KnowledgeSourceReference: Hashable, Sendable {
    enum SourceType: String, Sendable {
        case documentPage = "document_page"
        case document
        case note
    }

    var sourceType: SourceType
    var projectId: UUID
    var sourceId: UUID
    /// 0-based page index for `documentPage`; nil otherwise.
    var pageIndex: Int?
    var title: String
    var revision: String?
    var checksumSHA256: String?
    var fileRelativePath: String?

    var pageNumber: Int? { pageIndex.map { $0 + 1 } }

    /// Human-readable citation, e.g. `Specyfikacja izolacji (rev B), p. 4`.
    var citation: String {
        var text = title
        if let revision, !revision.isEmpty { text += " (rev \(revision))" }
        if let pageNumber { text += ", p. \(pageNumber)" }
        return text
    }
}

enum KnowledgeSearchScope: Hashable, Sendable {
    case all
    case documents
    case notes
    case category(DocumentCategory)

    var title: String {
        switch self {
        case .all: return "All"
        case .documents: return "Documents"
        case .notes: return "Notes"
        case .category(let category): return category.title
        }
    }

    var includesNotes: Bool {
        switch self {
        case .all, .notes: return true
        case .documents, .category: return false
        }
    }

    var includesDocuments: Bool {
        if case .notes = self { return false }
        return true
    }

    var categoryFilter: DocumentCategory? {
        if case .category(let category) = self { return category }
        return nil
    }
}

struct KnowledgeSearchResult: Identifiable, Hashable, Sendable {
    /// Start / end markers wrapped around matched terms inside `snippet`.
    static let matchStart: Character = "\u{E000}"
    static let matchEnd: Character = "\u{E001}"

    var reference: KnowledgeSourceReference
    var snippet: String
    var documentCategory: DocumentCategory?
    var noteCategory: NoteCategory?
    /// FTS5 bm25 score — lower is a better match.
    var rank: Double

    var id: String {
        "\(reference.sourceType.rawValue)-\(reference.sourceId.uuidString)-\(reference.pageIndex ?? -1)"
    }
}
