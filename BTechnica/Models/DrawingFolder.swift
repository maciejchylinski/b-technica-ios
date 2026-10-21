import Foundation

/// A user-defined nested folder for drawings within one project.
/// Field layout matches Supabase `drawing_folders` so local UUIDs stay sync-ready.
/// Local-only for now — not uploaded to Supabase yet.
struct DrawingFolder: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var projectId: UUID
    /// `nil` means the folder sits at the project root.
    var parentFolderId: UUID?
    var name: String
    var sortOrder: Int
    var createdDate: Date

    init(
        id: UUID = UUID(),
        projectId: UUID,
        parentFolderId: UUID? = nil,
        name: String,
        sortOrder: Int = 0,
        createdDate: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.parentFolderId = parentFolderId
        self.name = name
        self.sortOrder = sortOrder
        self.createdDate = createdDate
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, parentFolderId, name, sortOrder, createdDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        parentFolderId = try c.decodeIfPresent(UUID.self, forKey: .parentFolderId)
        name = try c.decode(String.self, forKey: .name)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(parentFolderId, forKey: .parentFolderId)
        try c.encode(name, forKey: .name)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdDate, forKey: .createdDate)
    }
}
