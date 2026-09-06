import Foundation

/// A photo attached to a field issue.
///
/// The image file lives on disk under `Documents/IssuePhotos/`; this record
/// stores only the relative file name so `appdata.json` stays small and the
/// path remains valid if the sandbox container moves between launches.
struct IssuePhoto: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    /// File name relative to Documents/IssuePhotos, e.g. "<uuid>.jpg".
    var fileName: String
    var createdDate: Date

    init(id: UUID = UUID(),
         fileName: String,
         createdDate: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.createdDate = createdDate
    }
}
