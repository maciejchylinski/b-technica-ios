import Foundation
import Supabase

/// Payload for pushing one local polygon area create to Supabase `areas`.
struct AreaCreatePayload: Equatable, Sendable {
    var id: UUID
    var projectId: UUID
    var drawingId: UUID
    var pageId: UUID
    var name: String
    var vertices: [PDFPoint]
    var color: String
    var opacity: Double
    var isVisible: Bool
    var createdDate: Date
    var updatedDate: Date
}

enum AreaRemoteCreateResult: Equatable {
    case created
    case alreadyPresent
}

enum AreaRemoteError: LocalizedError, Equatable {
    case conflict(String)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let message), .notReady(let message):
            return message
        }
    }
}

/// Remote API for creating local areas in Supabase (create-only).
protocol AreaRemoteStore: Sendable {
    /// Ensures an area row exists with the given local UUID. Never overwrites conflicts.
    func ensureCreated(_ payload: AreaCreatePayload) async throws -> AreaRemoteCreateResult
}

/// Supabase-backed create for `public.areas`.
struct SupabaseAreaRemoteStore: AreaRemoteStore {
    var client: SupabaseClient = SupabaseManager.client

    func ensureCreated(_ payload: AreaCreatePayload) async throws -> AreaRemoteCreateResult {
        try Self.validate(payload)

        if let existing = try await fetchActiveArea(id: payload.id) {
            try Self.verify(existing: existing, expected: payload)
            return .alreadyPresent
        }

        do {
            try await client
                .from("areas")
                .insert(AreaInsert(payload: payload), returning: .minimal)
                .execute()
            return .created
        } catch {
            if Self.isUniqueViolation(error),
               let existing = try await fetchActiveArea(id: payload.id) {
                try Self.verify(existing: existing, expected: payload)
                return .alreadyPresent
            }
            throw error
        }
    }

    // MARK: - Fetch

    private func fetchActiveArea(id: UUID) async throws -> RemoteAreaRow? {
        let rows: [RemoteAreaRow] = try await client
            .from("areas")
            .select(
                "id,project_id,drawing_id,page_id,name,vertices,color,opacity,is_visible,created_at,updated_at,deleted_at"
            )
            .eq("id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Consistency

    private static func validate(_ payload: AreaCreatePayload) throws {
        let trimmed = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AreaRemoteError.conflict("Empty area name")
        }
        guard payload.vertices.count >= 3 else {
            throw AreaRemoteError.conflict("Area requires at least 3 vertices")
        }
        guard payload.opacity >= 0, payload.opacity <= 1 else {
            throw AreaRemoteError.conflict("Invalid opacity \(payload.opacity)")
        }
    }

    private static func verify(existing: RemoteAreaRow, expected: AreaCreatePayload) throws {
        guard existing.projectId == expected.projectId else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) belongs to another project"
            )
        }
        guard existing.drawingId == expected.drawingId else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) drawing mismatch"
            )
        }
        guard existing.pageId == expected.pageId else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) page_id mismatch"
            )
        }
        guard existing.name == expected.name else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) name mismatch"
            )
        }
        guard existing.color == expected.color else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) color mismatch"
            )
        }
        guard abs(existing.opacity - expected.opacity) < 0.000_1 else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) opacity mismatch"
            )
        }
        guard existing.isVisible == expected.isVisible else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) is_visible mismatch"
            )
        }
        guard VertexCompare.equal(existing.vertices, expected.vertices) else {
            throw AreaRemoteError.conflict(
                "Remote area \(expected.id) vertices mismatch"
            )
        }
    }

    private static func isUniqueViolation(_ error: Error) -> Bool {
        if let pg = error as? PostgrestError, pg.code == "23505" {
            return true
        }
        let text = String(describing: error).lowercased()
        return text.contains("23505") || text.contains("duplicate key")
    }
}

// MARK: - Encodable / Decodable rows

private struct AreaInsert: Encodable {
    let id: String
    let projectId: String
    let drawingId: String
    let pageId: String
    let name: String
    let vertices: [VertexDTO]
    let color: String
    let opacity: Double
    let isVisible: Bool
    let createdAt: String
    let updatedAt: String

    init(payload: AreaCreatePayload) {
        id = payload.id.uuidString
        projectId = payload.projectId.uuidString
        drawingId = payload.drawingId.uuidString
        pageId = payload.pageId.uuidString
        name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        vertices = payload.vertices.map { VertexDTO(x: $0.x, y: $0.y) }
        color = payload.color
        opacity = payload.opacity
        isVisible = payload.isVisible
        createdAt = SQLiteDateCoding.string(from: payload.createdDate)
        updatedAt = SQLiteDateCoding.string(from: payload.updatedDate)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case drawingId = "drawing_id"
        case pageId = "page_id"
        case name
        case vertices
        case color
        case opacity
        case isVisible = "is_visible"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct VertexDTO: Codable, Equatable {
    let x: Double
    let y: Double
}

private struct RemoteAreaRow: Decodable {
    let id: UUID
    let projectId: UUID
    let drawingId: UUID
    let pageId: UUID
    let name: String
    let vertices: [VertexDTO]
    let color: String
    let opacity: Double
    let isVisible: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case drawingId = "drawing_id"
        case pageId = "page_id"
        case name
        case vertices
        case color
        case opacity
        case isVisible = "is_visible"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

private enum VertexCompare {
    static func equal(_ remote: [VertexDTO], _ local: [PDFPoint]) -> Bool {
        guard remote.count == local.count else { return false }
        for (lhs, rhs) in zip(remote, local) {
            if abs(lhs.x - rhs.x) > 0.000_1 || abs(lhs.y - rhs.y) > 0.000_1 {
                return false
            }
        }
        return true
    }
}
