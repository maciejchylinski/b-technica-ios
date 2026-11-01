import Foundation
import Supabase

/// Uploads drawing PDFs to the private `drawings` Storage bucket.
/// Paths are `{project_id}/{revision_id}.pdf` (bucket-relative). Never upserts over an
/// existing object that belongs to a different revision id.
protocol DrawingPDFRemoteStore: Sendable {
    func uploadPDF(localURL: URL, remotePath: String) async throws
    func objectExists(remotePath: String) async throws -> Bool
    func removePDF(remotePath: String) async throws
}

enum DrawingPDFRemoteError: LocalizedError, Equatable {
    case invalidLocalFile
    case uploadFailed(String)
    case remoteConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocalFile:
            return "Local PDF is missing or unreadable"
        case .uploadFailed(let detail):
            return "PDF upload failed: \(detail)"
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

    func objectExists(remotePath: String) async throws -> Bool {
        try await client.storage.from(bucket).exists(path: remotePath)
    }

    func removePDF(remotePath: String) async throws {
        _ = try await client.storage.from(bucket).remove(paths: [remotePath])
    }

    private static func describe(_ error: Error) -> String {
        if let storage = error as? StorageError {
            return "status=\(storage.statusCode ?? "?") message=\(storage.message)"
        }
        return error.localizedDescription
    }
}
