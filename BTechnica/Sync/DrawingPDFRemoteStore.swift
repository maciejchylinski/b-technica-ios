import Foundation
import Supabase

/// Uploads / downloads drawing PDFs against the private `drawings` Storage bucket.
/// Paths are `{project_id}/{revision_id}.pdf` (bucket-relative). Never upserts over an
/// existing object that belongs to a different revision id. Downloads never overwrite
/// an existing local PDF silently.
protocol DrawingPDFRemoteStore: Sendable {
    func uploadPDF(localURL: URL, remotePath: String) async throws
    /// Streams `remotePath` to disk (temp → validate → atomic move into `localURL`).
    /// Does not load the whole PDF into application memory. Skips if `localURL` already
    /// exists and is a valid PDF.
    func downloadPDF(remotePath: String, to localURL: URL) async throws
    func objectExists(remotePath: String) async throws -> Bool
    func removePDF(remotePath: String) async throws
}

enum DrawingPDFRemoteError: LocalizedError, Equatable {
    case invalidLocalFile
    case uploadFailed(String)
    case downloadFailed(String)
    case remoteConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocalFile:
            return "Local PDF is missing or unreadable"
        case .uploadFailed(let detail):
            return "PDF upload failed: \(detail)"
        case .downloadFailed(let detail):
            return "PDF download failed: \(detail)"
        case .remoteConflict(let detail):
            return "Remote PDF conflict: \(detail)"
        }
    }
}

struct SupabaseDrawingPDFRemoteStore: DrawingPDFRemoteStore {
    private let client: SupabaseClient
    private let bucket = "drawings"

    init(client: SupabaseClient = SupabaseManager.client) {
        self.client = client
    }

    func uploadPDF(localURL: URL, remotePath: String) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw DrawingPDFRemoteError.invalidLocalFile
        }

        // Same revision path already present (prior attempt succeeded remotely) → done.
        if try await objectExists(remotePath: remotePath) {
            return
        }

        let options = FileOptions(
            cacheControl: "3600",
            contentType: "application/pdf",
            upsert: false
        )

        do {
            _ = try await client.storage
                .from(bucket)
                .upload(remotePath, fileURL: localURL, options: options)
        } catch {
            // Race: another attempt finished first for this exact path — confirm, don't overwrite.
            if try await objectExists(remotePath: remotePath) {
                return
            }
            throw DrawingPDFRemoteError.uploadFailed(Self.describe(error))
        }

        guard try await objectExists(remotePath: remotePath) else {
            throw DrawingPDFRemoteError.uploadFailed("Upload returned without a confirmable object")
        }
    }

    func downloadPDF(remotePath: String, to localURL: URL) async throws {
        let fm = FileManager.default

        // Preserve existing local PDFs — never overwrite silently.
        if fm.fileExists(atPath: localURL.path) {
            guard Self.isValidPDF(at: localURL) else {
                throw DrawingPDFRemoteError.downloadFailed(
                    "Local file exists but is not a valid PDF"
                )
            }
            return
        }

        guard try await objectExists(remotePath: remotePath) else {
            throw DrawingPDFRemoteError.downloadFailed("Remote object missing: \(remotePath)")
        }

        // Authenticated short-lived URL, then URLSession streams to a temp file on disk
        // (avoids loading the entire PDF into application memory).
        let signedURL: URL
        do {
            signedURL = try await client.storage
                .from(bucket)
                .createSignedURL(path: remotePath, expiresIn: 600)
        } catch {
            throw DrawingPDFRemoteError.downloadFailed(Self.describe(error))
        }

        let sessionTempURL: URL
        let response: URLResponse
        do {
            (sessionTempURL, response) = try await URLSession.shared.download(from: signedURL)
        } catch {
            throw DrawingPDFRemoteError.downloadFailed(Self.describe(error))
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? fm.removeItem(at: sessionTempURL)
            throw DrawingPDFRemoteError.downloadFailed(
                "HTTP \(http.statusCode) downloading \(remotePath)"
            )
        }

        let parent = localURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(localURL.lastPathComponent).\(UUID().uuidString).download"
        )
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }

        var stagingOwned = true
        defer {
            if stagingOwned {
                try? fm.removeItem(at: staging)
            }
        }

        do {
            try fm.moveItem(at: sessionTempURL, to: staging)
        } catch {
            try? fm.removeItem(at: sessionTempURL)
            throw DrawingPDFRemoteError.downloadFailed(Self.describe(error))
        }

        guard Self.isValidPDF(at: staging) else {
            throw DrawingPDFRemoteError.downloadFailed("Downloaded bytes are not a valid PDF")
        }

        // Another writer may have created the destination while we streamed.
        if fm.fileExists(atPath: localURL.path) {
            guard Self.isValidPDF(at: localURL) else {
                throw DrawingPDFRemoteError.downloadFailed(
                    "Destination exists but is not a valid PDF"
                )
            }
            return
        }

        do {
            try fm.moveItem(at: staging, to: localURL)
            stagingOwned = false
        } catch {
            // Lost the race to another successful download.
            if fm.fileExists(atPath: localURL.path), Self.isValidPDF(at: localURL) {
                return
            }
            throw DrawingPDFRemoteError.downloadFailed(Self.describe(error))
        }
    }

    func objectExists(remotePath: String) async throws -> Bool {
        try await client.storage.from(bucket).exists(path: remotePath)
    }

    func removePDF(remotePath: String) async throws {
        _ = try await client.storage.from(bucket).remove(paths: [remotePath])
    }

    /// Minimal PDF magic-byte check (%PDF) without loading the whole document.
    private static func isValidPDF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 5)
        guard header.count >= 5 else { return false }
        return header.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
    }

    private static func describe(_ error: Error) -> String {
        if let storage = error as? StorageError {
            return "status=\(storage.statusCode ?? "?") message=\(storage.message)"
        }
        return error.localizedDescription
    }
}
