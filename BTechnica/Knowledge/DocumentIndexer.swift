import Foundation
import PDFKit

/// Indexes one project document into `project_document_pages` (+ FTS via triggers).
/// Synchronous and thread-agnostic: run it from a background task, never the main actor.
enum DocumentIndexer {
    enum Outcome: Equatable, Sendable {
        /// File and extractor unchanged since the last successful index.
        case skippedUnchanged
        case indexed(pages: Int, textPages: Int, ocrPages: Int)
        case failed(String)
        case cancelled
    }

    struct Progress: Equatable, Sendable {
        var documentId: UUID
        var completedPages: Int
        var totalPages: Int
    }

    static func index(
        documentId: UUID,
        projectId: UUID,
        database: AppDatabase,
        projectRootURL: URL,
        allowOCR: Bool = true,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled },
        onProgress: ((Progress) -> Void)? = nil
    ) -> Outcome {
        do {
            guard let document = try database.fetchProjectDocument(id: documentId, projectId: projectId) else {
                return .failed(AppDatabase.KnowledgeError.notFound.localizedDescription)
            }

            let url = DocumentFileStorage.fileURL(
                projectRootURL: projectRootURL,
                relativePath: document.fileRelativePath
            )
            guard fileManager.fileExists(atPath: url.path) else {
                let message = "The PDF file is missing from this device."
                try database.markDocumentIndexFailed(id: documentId, error: message)
                return .failed(message)
            }

            let checksum = try DocumentFileStorage.sha256Hex(of: url)
            if document.indexedChecksum == checksum,
               document.extractorVersion == DocumentTextExtractor.version {
                try database.markDocumentIndexUnchanged(id: documentId)
                return .skippedUnchanged
            }

            try database.markDocumentIndexing(
                id: documentId,
                checksum: checksum,
                fileSizeBytes: DocumentFileStorage.fileSize(at: url, fileManager: fileManager)
            )

            guard let pdf = PDFDocument(url: url) else {
                let message = "The PDF could not be opened. It may be damaged."
                try database.markDocumentIndexFailed(id: documentId, error: message)
                return .failed(message)
            }
            if pdf.isLocked && !pdf.unlock(withPassword: "") {
                let message = ProjectDocument.lockedPDFMessage
                try database.markDocumentIndexFailed(id: documentId, error: message)
                return .failed(message)
            }

            try database.deleteDocumentPages(documentId: documentId)

            let total = pdf.pageCount
            var textPages = 0
            var ocrPages = 0
            onProgress?(Progress(documentId: documentId, completedPages: 0, totalPages: total))
            for index in 0..<total {
                if isCancelled() {
                    try? database.requestDocumentIndexing(id: documentId, projectId: projectId, force: true)
                    return .cancelled
                }
                guard let page = pdf.page(at: index) else { continue }
                let result = DocumentTextExtractor.extract(page: page, pageIndex: index, allowOCR: allowOCR)
                switch result.method {
                case .pdfText: textPages += 1
                case .ocr: ocrPages += 1
                case .noText: break
                }
                try database.upsertDocumentPage(
                    ProjectDocumentPage(
                        documentId: documentId,
                        projectId: projectId,
                        pageIndex: index,
                        pageLabel: result.pageLabel,
                        text: result.text,
                        extractionMethod: result.method,
                        ocrConfidence: result.ocrConfidence,
                        extractedAt: Date()
                    )
                )
                onProgress?(Progress(documentId: documentId, completedPages: index + 1, totalPages: total))
            }

            let summary: DocumentExtractionSummary
            switch (textPages > 0, ocrPages > 0) {
            case (true, true): summary = .mixed
            case (true, false): summary = .pdfText
            case (false, true): summary = .ocr
            case (false, false): summary = .noText
            }
            try database.markDocumentIndexed(
                id: documentId,
                checksum: checksum,
                extractorVersion: DocumentTextExtractor.version,
                pageCount: total,
                summary: summary,
                textPageCount: textPages,
                ocrPageCount: ocrPages
            )
            return .indexed(pages: total, textPages: textPages, ocrPages: ocrPages)
        } catch {
            let message = error.localizedDescription
            try? database.markDocumentIndexFailed(id: documentId, error: message)
            return .failed(message)
        }
    }
}
