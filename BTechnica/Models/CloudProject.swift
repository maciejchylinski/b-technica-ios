import Foundation

/// A project row from Supabase `public.projects`.
/// Separate from local `Project` so cloud listing never mixes with on-device AppData.
struct CloudProject: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }
}
