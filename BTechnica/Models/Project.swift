import Foundation

/// Local project identity mirrored from a cloud `projects` row.
/// Drawings/issues for this id live under the per-project local workspace folder.
struct Project: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdDate: Date

    init(id: UUID = UUID(), name: String, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
    }
}
