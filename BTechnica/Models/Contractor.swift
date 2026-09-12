import Foundation

/// A local contractor entry for the project dictionary.
///
/// Issues still store the contractor as a plain name string for backward
/// compatibility with existing free-text data. This record is the controlled
/// source of picker options for new/edited selections.
struct Contractor: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// Optional trade or short notes (e.g. "Electrical sub").
    var notes: String?
    var createdDate: Date

    init(id: UUID = UUID(),
         name: String,
         notes: String? = nil,
         createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdDate = createdDate
    }
}
