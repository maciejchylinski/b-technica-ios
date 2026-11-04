import CryptoKit
import Foundation
import PDFKit

/// Project-scoped on-disk storage for library PDFs:
/// `Documents/Users/<userId>/Projects/<projectId>/ProjectDocuments/<documentId>.pdf`.
/// Originals are copied byte-for-byte and never modified.
enum DocumentFileStorage {
    static let directoryName = "ProjectDocuments"

    enum ImportError: LocalizedError {
        case unreadable(String)
        case emptyFile(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\u{201C}\(name)\u{201D} is not a readable PDF."
            case .emptyFile(let name): return "\u{201C}\(name)\u{201D} is empty."
            }
        }
    }

    struct StoredFile: Sendable {
        var relativePath: String
        var fileSizeBytes: Int64
        var checksumSHA256: String
        var pageCount: Int
        var isLocked: Bool
    }

    static func projectRootURL(userRootURL: URL, projectId: UUID) -> URL {
        userRootURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
    }

    static func fileURL(projectRootURL: URL, relativePath: String) -> URL {
        projectRootURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Copies a picked PDF into project storage and validates it. Runs off the main thread.
    /// The copy is streamed by the file system; the PDF is never read fully into memory.
    static func storePDF(
        from sourceURL: URL,
        documentId: UUID,
        projectRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> StoredFile {
        let needsStop = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsStop { sourceURL.stopAccessingSecurityScopedResource() } }

        let displayName = sourceURL.lastPathComponent
        let directory = projectRootURL.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let relativePath = "\(directoryName)/\(documentId.uuidString).pdf"
        let destination = fileURL(projectRootURL: projectRootURL, relativePath: relativePath)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        do {
            let size = fileSize(at: destination, fileManager: fileManager) ?? 0
            guard size > 0 else { throw ImportError.emptyFile(displayName) }
            guard let pdf = PDFDocument(url: destination) else { throw ImportError.unreadable(displayName) }
            let locked = pdf.isLocked && !pdf.unlock(withPassword: "")
            let checksum = try sha256Hex(of: destination)
            return StoredFile(
                relativePath: relativePath,
                fileSizeBytes: size,
                checksumSHA256: checksum,
                pageCount: pdf.pageCount,
                isLocked: locked
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// SHA-256 of a file, read in 1 MiB chunks.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func removeFile(projectRootURL: URL, relativePath: String, fileManager: FileManager = .default) {
        guard !relativePath.isEmpty else { return }
        let url = fileURL(projectRootURL: projectRootURL, relativePath: relativePath)
        try? fileManager.removeItem(at: url)
    }
}

extension ProjectDocument {
    static let lockedPDFMessage = "The PDF is password-protected, so its text cannot be read."

    /// New library record for a freshly stored PDF, queued for indexing.
    static func imported(
        id: UUID,
        projectId: UUID,
        folderId: UUID?,
        originalFileName: String,
        stored: DocumentFileStorage.StoredFile,
        category: DocumentCategory = .other,
        now: Date = Date()
    ) -> ProjectDocument {
        let baseName = (originalFileName as NSString).deletingPathExtension
        return ProjectDocument(
            id: id,
            projectId: projectId,
            folderId: folderId,
            name: baseName.isEmpty ? "Document" : baseName,
            category: category,
            descriptionText: "",
            originalFileName: originalFileName,
            fileRelativePath: stored.relativePath,
            fileSizeBytes: stored.fileSizeBytes,
            pageCount: stored.pageCount,
            checksumSHA256: stored.checksumSHA256,
            revision: nil,
            revisionDate: nil,
            uploadedAt: now,
            updatedAt: now,
            indexStatus: stored.isLocked ? .failed : .pending,
            indexError: stored.isLocked ? lockedPDFMessage : nil,
            indexAttempts: 0,
            indexStartedAt: nil,
            indexedAt: nil,
            indexedChecksum: nil,
            extractorVersion: nil,
            extractionSummary: nil,
            textPageCount: 0,
            ocrPageCount: 0
        )
    }
}
