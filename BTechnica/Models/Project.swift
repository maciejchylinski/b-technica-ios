import Foundation

/// A construction project. For this first slice there is a single default
/// project created on first launch, but the model is already project-scoped so
/// multiple projects can be added later without a data migration.
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
