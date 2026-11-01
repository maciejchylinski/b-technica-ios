import Foundation
import Supabase

/// Payload for pushing one local drawing's cloud metadata (drawing + current revision + pages).
/// `revisionId` / `storagePath` come from the completed PDF `file_transfers.remote_path`.
struct DrawingMetadataPayload: Equatable, Sendable {
    var id: UUID
    var projectId: UUID
    var folderId: UUID?
    var name: String
    var fileName: String
    var pageCount: Int
    var createdDate: Date
    var revisionLabel: String?
    var discipline: String?
    var location: String?
    var drawingDate: Date?
    var revisionId: UUID
    var storagePath: String
}

enum DrawingRemoteCreateResult: Equatable {
    case created
    case alreadyPresent
}

/// Remote API for pushing local drawing metadata (no download).
protocol DrawingRemoteStore: Sendable {
    /// Ensures drawing + current revision + pages exist. Never overwrites conflicting rows.
    func ensureCreated(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult
}

enum DrawingRemoteError: LocalizedError, Equatable {
    case conflict(String)
    case pdfNotUploaded(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let message), .pdfNotUploaded(let message):
            return message
        }
    }
}

/// Supabase-backed mutations for `drawings`, `drawing_revisions`, and `drawing_pages`.
struct SupabaseDrawingRemoteStore: DrawingRemoteStore {
    var client: SupabaseClient = SupabaseManager.client

    func ensureCreated(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult {
        try Self.validatePayload(payload)

        let drawingResult = try await ensureDrawingRow(payload)
        let revisionResult = try await ensureRevisionRow(payload)
        try await ensurePages(payload)

        if drawingResult == .alreadyPresent, revisionResult == .alreadyPresent {
            return .alreadyPresent
        }
        return .created
    }

    // MARK: - Drawing

    private func ensureDrawingRow(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult {
        if let existing = try await fetchActiveDrawing(id: payload.id) {
            try Self.verifyDrawing(existing: existing, expected: payload)
            return .alreadyPresent
        }

        do {
            try await client
                .from("drawings")
                .insert(DrawingInsert(payload: payload), returning: .minimal)
                .execute()
            return .created
        } catch {
            if Self.isUniqueViolation(error),
               let existing = try await fetchActiveDrawing(id: payload.id) {
                try Self.verifyDrawing(existing: existing, expected: payload)
                return .alreadyPresent
            }
            throw error
        }
    }

    // MARK: - Revision

    private func ensureRevisionRow(_ payload: DrawingMetadataPayload) async throws -> DrawingRemoteCreateResult {
        if let existing = try await fetchActiveRevision(id: payload.revisionId) {
            try Self.verifyRevision(existing: existing, expected: payload)
            return .alreadyPresent
        }

        do {
            try await client
                .from("drawing_revisions")
                .insert(RevisionInsert(payload: payload), returning: .minimal)
                .execute()
            return .created
        } catch {
            if Self.isUniqueViolation(error),
               let existing = try await fetchActiveRevision(id: payload.revisionId) {
                try Self.verifyRevision(existing: existing, expected: payload)
                return .alreadyPresent
            }
            throw error
        }
    }

    // MARK: - Pages

    private func ensurePages(_ payload: DrawingMetadataPayload) async throws {
        let existing = try await fetchActivePages(revisionId: payload.revisionId)
        let byIndex = Dictionary(uniqueKeysWithValues: existing.map { ($0.pageIndex, $0) })

        for index in 0..<payload.pageCount {
            if byIndex[index] != nil { continue }
            do {
                try await client
                    .from("drawing_pages")
                    .insert(
                        PageInsert(revisionId: payload.revisionId, pageIndex: index),
                        returning: .minimal
                    )
                    .execute()
            } catch {
                if Self.isUniqueViolation(error) {
                    // Concurrent insert of the same page_index — treat as present.
                    continue
                }
                throw error
            }
        }

        let after = try await fetchActivePages(revisionId: payload.revisionId)
        let indexes = Set(after.map(\.pageIndex))
        for index in 0..<payload.pageCount {
            guard indexes.contains(index) else {
                throw DrawingRemoteError.conflict(
                    "Missing drawing_pages row revision=\(payload.revisionId) page=\(index)"
                )
            }
        }
    }

    // MARK: - Fetch

    private func fetchActiveDrawing(id: UUID) async throws -> RemoteDrawingRow? {
        let rows: [RemoteDrawingRow] = try await client
            .from("drawings")
            .select("id,project_id,folder_id,name,discipline,location,created_at,deleted_at")
            .eq("id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func fetchActiveRevision(id: UUID) async throws -> RemoteRevisionRow? {
        let rows: [RemoteRevisionRow] = try await client
            .from("drawing_revisions")
            .select(
                "id,drawing_id,revision_label,storage_path,original_file_name,page_count,is_current,deleted_at"
            )
            .eq("id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func fetchActivePages(revisionId: UUID) async throws -> [RemotePageRow] {
        try await client
            .from("drawing_pages")
            .select("id,revision_id,page_index,deleted_at")
            .eq("revision_id", value: revisionId.uuidString)
            .is("deleted_at", value: nil)
            .order("page_index", ascending: true)
            .execute()
            .value
    }

    // MARK: - Consistency

    private static func validatePayload(_ payload: DrawingMetadataPayload) throws {
        guard payload.pageCount >= 0 else {
            throw DrawingRemoteError.conflict("Invalid page_count \(payload.pageCount)")
        }
        guard !payload.storagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DrawingRemoteError.conflict("Empty storage_path")
        }
        let expectedPath = AppDatabase.drawingPDFRemotePath(
            projectId: payload.projectId,
            revisionId: payload.revisionId
        )
        guard payload.storagePath == expectedPath else {
            throw DrawingRemoteError.conflict(
                "storage_path \(payload.storagePath) does not match revision \(payload.revisionId)"
            )
        }
    }

    private static func verifyDrawing(existing: RemoteDrawingRow, expected: DrawingMetadataPayload) throws {
        guard existing.projectId == expected.projectId else {
            throw DrawingRemoteError.conflict(
                "Remote drawing \(expected.id) belongs to another project"
            )
        }
        guard existing.folderId == expected.folderId else {
            throw DrawingRemoteError.conflict(
                "Remote drawing \(expected.id) folder mismatch"
            )
        }
        guard existing.name == expected.name else {
            throw DrawingRemoteError.conflict(
                "Remote drawing \(expected.id) name mismatch"
            )
        }
        guard Self.optionalEqual(existing.discipline, expected.discipline),
              Self.optionalEqual(existing.location, expected.location)
        else {
            throw DrawingRemoteError.conflict(
                "Remote drawing \(expected.id) discipline/location mismatch"
            )
        }
    }

    private static func verifyRevision(existing: RemoteRevisionRow, expected: DrawingMetadataPayload) throws {
        guard existing.drawingId == expected.id else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) belongs to another drawing"
            )
        }
        guard existing.storagePath == expected.storagePath else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) storage_path mismatch"
            )
        }
        guard existing.pageCount == expected.pageCount else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) page_count mismatch"
            )
        }
        guard existing.isCurrent else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) is not current"
            )
        }
        let expectedOriginal = expected.fileName
        let existingOriginal = existing.originalFileName ?? expectedOriginal
        guard existingOriginal == expectedOriginal else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) original_file_name mismatch"
            )
        }
        guard Self.optionalEqual(existing.revisionLabel, expected.revisionLabel) else {
            throw DrawingRemoteError.conflict(
                "Remote revision \(expected.revisionId) revision_label mismatch"
            )
        }
    }

    private static func optionalEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        Drawing.nonEmpty(lhs) == Drawing.nonEmpty(rhs)
    }

    private static func isUniqueViolation(_ error: Error) -> Bool {
        if let pg = error as? PostgrestError, pg.code == "23505" {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("duplicate") || text.contains("unique") || text.contains("23505")
    }
}

// MARK: - Insert / row DTOs

private struct DrawingInsert: Encodable {
    let id: String
    let projectId: String
    let folderId: String?
    let name: String
    let discipline: String?
    let location: String?
    let createdAt: String

    init(payload: DrawingMetadataPayload) {
        id = payload.id.uuidString
        projectId = payload.projectId.uuidString
        folderId = payload.folderId?.uuidString
        name = payload.name
        discipline = Drawing.nonEmpty(payload.discipline)
        location = Drawing.nonEmpty(payload.location)
        createdAt = SQLiteDateCoding.string(from: payload.createdDate)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case folderId = "folder_id"
        case name
        case discipline
        case location
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(folderId, forKey: .folderId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(discipline, forKey: .discipline)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

private struct RevisionInsert: Encodable {
    let id: String
    let drawingId: String
    let revisionLabel: String?
    let storagePath: String
    let originalFileName: String
    let pageCount: Int
    let drawingDate: String?
    let isCurrent: Bool

    init(payload: DrawingMetadataPayload) {
        id = payload.revisionId.uuidString
        drawingId = payload.id.uuidString
        revisionLabel = Drawing.nonEmpty(payload.revisionLabel)
        storagePath = payload.storagePath
        originalFileName = payload.fileName
        pageCount = payload.pageCount
        drawingDate = payload.drawingDate.map(Self.dateOnly)
        isCurrent = true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case drawingId = "drawing_id"
        case revisionLabel = "revision_label"
        case storagePath = "storage_path"
        case originalFileName = "original_file_name"
        case pageCount = "page_count"
        case drawingDate = "drawing_date"
        case isCurrent = "is_current"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(drawingId, forKey: .drawingId)
        try c.encodeIfPresent(revisionLabel, forKey: .revisionLabel)
        try c.encode(storagePath, forKey: .storagePath)
        try c.encode(originalFileName, forKey: .originalFileName)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encodeIfPresent(drawingDate, forKey: .drawingDate)
        try c.encode(isCurrent, forKey: .isCurrent)
    }

    private static func dateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct PageInsert: Encodable {
    let id: String
    let revisionId: String
    let pageIndex: Int

    init(revisionId: UUID, pageIndex: Int) {
        id = UUID().uuidString
        self.revisionId = revisionId.uuidString
        self.pageIndex = pageIndex
    }

    enum CodingKeys: String, CodingKey {
        case id
        case revisionId = "revision_id"
        case pageIndex = "page_index"
    }
}

private struct RemoteDrawingRow: Decodable {
    let id: UUID
    let projectId: UUID
    let folderId: UUID?
    let name: String
    let discipline: String?
    let location: String?
    let createdAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case folderId = "folder_id"
        case name
        case discipline
        case location
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }
}

private struct RemoteRevisionRow: Decodable {
    let id: UUID
    let drawingId: UUID
    let revisionLabel: String?
    let storagePath: String
    let originalFileName: String?
    let pageCount: Int
    let isCurrent: Bool
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case drawingId = "drawing_id"
        case revisionLabel = "revision_label"
        case storagePath = "storage_path"
        case originalFileName = "original_file_name"
        case pageCount = "page_count"
        case isCurrent = "is_current"
        case deletedAt = "deleted_at"
    }
}

private struct RemotePageRow: Decodable {
    let id: UUID
    let revisionId: UUID
    let pageIndex: Int
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case revisionId = "revision_id"
        case pageIndex = "page_index"
        case deletedAt = "deleted_at"
    }
}
