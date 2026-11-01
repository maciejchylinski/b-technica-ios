import Foundation
import Supabase

/// Result of an idempotent remote folder create.
enum DrawingFolderRemoteCreateResult: Equatable {
    /// Row inserted on the remote.
    case created
    /// Row with the same id already existed and matched ownership/consistency.
    case alreadyPresent
}

/// Result of an idempotent remote folder rename.
enum DrawingFolderRemoteRenameResult: Equatable {
    case updated
    case alreadyApplied
}

/// Result of an idempotent remote folder soft-delete.
enum DrawingFolderRemoteDeleteResult: Equatable {
    case deleted
    case alreadyDeleted
}

/// Remote API for pushing local drawing-folder mutations.
protocol DrawingFolderRemoteStore: Sendable {
    /// Ensures a folder row exists with the given local UUID.
    /// Must not overwrite an existing conflicting row.
    func ensureCreated(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteCreateResult

    /// Renames an existing remote folder. Must not overwrite unrelated / conflicting rows.
    func ensureRenamed(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteRenameResult

    /// Soft-deletes a folder remotely (`deleted_at`). Idempotent if already gone.
    func ensureDeleted(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteDeleteResult
}

/// Supabase-backed mutations for `public.drawing_folders`.
struct SupabaseDrawingFolderRemoteStore: DrawingFolderRemoteStore {
    var client: SupabaseClient = SupabaseManager.client

    func ensureCreated(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteCreateResult {
        if let existing = try await fetchActiveFolder(id: folder.id) {
            try Self.verifyOwnershipAndConsistency(existing: existing, expected: folder)
            return .alreadyPresent
        }

        do {
            try await client
                .from("drawing_folders")
                .insert(DrawingFolderInsert(folder: folder), returning: .minimal)
                .execute()
            return .created
        } catch {
            if Self.isUniqueViolation(error),
               let existing = try await fetchActiveFolder(id: folder.id) {
                try Self.verifyOwnershipAndConsistency(existing: existing, expected: folder)
                return .alreadyPresent
            }
            throw error
        }
    }

    func ensureRenamed(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteRenameResult {
        guard let existing = try await fetchActiveFolder(id: folder.id) else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(folder.id) missing for rename"
            )
        }
        guard existing.projectId == folder.projectId else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(folder.id) belongs to another project"
            )
        }
        if existing.name == folder.name {
            return .alreadyApplied
        }

        do {
            let updated: [RemoteFolderRow] = try await client
                .from("drawing_folders")
                .update(DrawingFolderRenameUpdate(name: folder.name))
                .eq("id", value: folder.id.uuidString)
                .eq("project_id", value: folder.projectId.uuidString)
                .is("deleted_at", value: nil)
                .select("id,project_id,parent_folder_id,name,sort_order,deleted_at")
                .execute()
                .value
            guard let row = updated.first else {
                throw DrawingFolderRemoteError.conflict(
                    "Rename affected no remote rows for \(folder.id)"
                )
            }
            guard row.name == folder.name else {
                throw DrawingFolderRemoteError.conflict(
                    "Remote rename did not apply for \(folder.id)"
                )
            }
            return .updated
        } catch {
            if Self.isUniqueViolation(error) {
                throw DrawingFolderRemoteError.conflict(
                    "Remote sibling name conflict renaming \(folder.id)"
                )
            }
            throw error
        }
    }

    func ensureDeleted(_ folder: DrawingFolder) async throws -> DrawingFolderRemoteDeleteResult {
        if let existing = try await fetchFolder(id: folder.id) {
            guard existing.projectId == folder.projectId else {
                throw DrawingFolderRemoteError.conflict(
                    "Remote folder \(folder.id) belongs to another project"
                )
            }
            if existing.deletedAt != nil {
                return .alreadyDeleted
            }
        } else {
            return .alreadyDeleted
        }

        let stamp = SQLiteDateCoding.string(from: Date())
        try await client
            .from("drawing_folders")
            .update(DrawingFolderSoftDeleteUpdate(deletedAt: stamp), returning: .minimal)
            .eq("id", value: folder.id.uuidString)
            .eq("project_id", value: folder.projectId.uuidString)
            .is("deleted_at", value: nil)
            .execute()

        if let after = try await fetchFolder(id: folder.id), after.deletedAt != nil {
            return .deleted
        }
        // Race: another client soft-deleted between fetch and update.
        return .alreadyDeleted
    }

    /// Active (non-tombstone) folder only — used by create/rename.
    private func fetchActiveFolder(id: UUID) async throws -> RemoteFolderRow? {
        let rows: [RemoteFolderRow] = try await client
            .from("drawing_folders")
            .select("id,project_id,parent_folder_id,name,sort_order,deleted_at")
            .eq("id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Any visible row including soft-deleted tombstones.
    private func fetchFolder(id: UUID) async throws -> RemoteFolderRow? {
        let rows: [RemoteFolderRow] = try await client
            .from("drawing_folders")
            .select("id,project_id,parent_folder_id,name,sort_order,deleted_at")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private static func verifyOwnershipAndConsistency(
        existing: RemoteFolderRow,
        expected: DrawingFolder
    ) throws {
        guard existing.projectId == expected.projectId else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(expected.id) belongs to another project"
            )
        }
        guard existing.parentFolderId == expected.parentFolderId else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(expected.id) parent mismatch"
            )
        }
        guard existing.name.lowercased() == expected.name.lowercased() else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(expected.id) name mismatch"
            )
        }
        guard existing.sortOrder == expected.sortOrder else {
            throw DrawingFolderRemoteError.conflict(
                "Remote folder \(expected.id) sort_order mismatch"
            )
        }
    }

    private static func isUniqueViolation(_ error: Error) -> Bool {
        if let pg = error as? PostgrestError, pg.code == "23505" {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("duplicate") || text.contains("unique") || text.contains("23505")
    }
}

enum DrawingFolderRemoteError: LocalizedError {
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let message):
            return message
        }
    }
}

private struct DrawingFolderInsert: Encodable {
    let id: String
    let projectId: String
    let parentFolderId: String?
    let name: String
    let sortOrder: Int
    let createdAt: String

    init(folder: DrawingFolder) {
        id = folder.id.uuidString
        projectId = folder.projectId.uuidString
        parentFolderId = folder.parentFolderId?.uuidString
        name = folder.name
        sortOrder = folder.sortOrder
        createdAt = SQLiteDateCoding.string(from: folder.createdDate)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case parentFolderId = "parent_folder_id"
        case name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        // Omit null parent so PostgREST matches root-folder inserts.
        try c.encodeIfPresent(parentFolderId, forKey: .parentFolderId)
        try c.encode(name, forKey: .name)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

private struct DrawingFolderRenameUpdate: Encodable {
    let name: String
}

private struct DrawingFolderSoftDeleteUpdate: Encodable {
    let deletedAt: String

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}

private struct RemoteFolderRow: Decodable {
    let id: UUID
    let projectId: UUID
    let parentFolderId: UUID?
    let name: String
    let sortOrder: Int
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case parentFolderId = "parent_folder_id"
        case name
        case sortOrder = "sort_order"
        case deletedAt = "deleted_at"
    }
}
