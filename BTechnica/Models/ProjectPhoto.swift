import Foundation

/// A construction documentation photo, independent of issues.
///
/// Image bytes live on disk under `Projects/<projectId>/Photos/`; `fileName` and
/// `thumbnailFileName` are relative to the project root so the record survives sandbox moves.
/// Local only until a sync slice uploads it (`syncStatus == "local_only"`).
struct ProjectPhoto: Identifiable, Equatable, Hashable {
    var id: UUID
    var projectId: UUID
    var albumId: UUID?
    var fileName: String
    var thumbnailFileName: String?
    var title: String?
    var description: String
    /// When the photo was taken (EXIF date for library imports, capture time for camera).
    var takenDate: Date
    var drawingId: UUID?
    var pageIndex: Int?
    var areaId: UUID?
    var issueId: UUID?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteSize: Int?
    var syncStatus: String
    var createdDate: Date
    var updatedDate: Date

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return takenDate.formatted(date: .abbreviated, time: .shortened)
    }
}

/// User-defined photo album within one project.
struct PhotoAlbum: Identifiable, Equatable, Hashable {
    var id: UUID
    var projectId: UUID
    var name: String
    var sortOrder: Int
    var createdDate: Date
    var updatedDate: Date
}
