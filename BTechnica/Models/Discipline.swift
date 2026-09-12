import Foundation

/// A local discipline / category entry for the project dictionary.
///
/// Issues still store the discipline as a plain name string for backward
/// compatibility with existing free-text data. This record is the controlled
/// source of picker options for new/edited selections.
struct Discipline: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var createdDate: Date

    init(id: UUID = UUID(),
         name: String,
         createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
    }
}
