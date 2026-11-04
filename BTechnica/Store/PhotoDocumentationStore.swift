import Foundation
import UIKit

/// Project photo documentation (gallery + albums) backed by the per-user SQLite database.
/// Files live under `Projects/<projectId>/Photos/` (originals) and `Photos/Thumbnails/`.
/// Local only; not synced to Supabase yet.
@MainActor
final class PhotoDocumentationStore: ObservableObject {
    @Published private(set) var photos: [ProjectPhoto] = []
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    let userId: UUID
    let projectId: UUID
    let projectRootURL: URL
    private let database: AppDatabase?

    init(userId: UUID, projectId: UUID) {
        self.userId = userId
        self.projectId = projectId
        self.projectRootURL = Self.projectRootURL(userId: userId, projectId: projectId)
        do {
            database = try AppDatabase.shared(for: userId)
        } catch {
            database = nil
            errorMessage = "Photos could not be opened: \(error.localizedDescription)"
        }
        reload()
    }

    static func projectRootURL(userId: UUID, projectId: UUID) -> URL {
        AppDatabase.userRootURL(for: userId)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
    }

    func reload() {
        guard let database else { return }
        do {
            photos = try database.fetchProjectPhotos(projectId: projectId)
            albums = try database.fetchPhotoAlbums(projectId: projectId)
        } catch {
            errorMessage = "Photos could not be loaded: \(error.localizedDescription)"
        }
    }

    // MARK: - Files

    func fileURL(for photo: ProjectPhoto) -> URL {
        projectRootURL.appendingPathComponent(photo.fileName)
    }

    func thumbnailURL(for photo: ProjectPhoto) -> URL? {
        photo.thumbnailFileName.map { projectRootURL.appendingPathComponent($0) }
    }

    func isFileMissing(_ photo: ProjectPhoto) -> Bool {
        !FileManager.default.fileExists(atPath: fileURL(for: photo).path)
    }

    func album(id: UUID?) -> PhotoAlbum? {
        guard let id else { return nil }
        return albums.first { $0.id == id }
    }

    func photo(id: UUID) -> ProjectPhoto? {
        photos.first { $0.id == id }
    }

    // MARK: - Import

    struct ImportDefaults {
        var albumId: UUID?
        var issueId: UUID?
        var drawingId: UUID?
        var pageIndex: Int?
        var areaId: UUID?
    }

    /// Processes and stores images (camera JPEG or library data, incl. HEIC) off the main
    /// thread, then inserts all rows in one transaction. Returns the new photos.
    @discardableResult
    func importImages(_ sources: [Data], useCaptureTime: Bool = false, defaults: ImportDefaults = ImportDefaults()) async -> [ProjectPhoto] {
        guard let database, !sources.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }

        let root = projectRootURL
        let projectId = projectId
        let written = await Task.detached(priority: .userInitiated) { () -> (photos: [ProjectPhoto], failed: Int) in
            let fm = FileManager.default
            let photosDir = root.appendingPathComponent("Photos", isDirectory: true)
            let thumbsDir = photosDir.appendingPathComponent("Thumbnails", isDirectory: true)
            try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            var result: [ProjectPhoto] = []
            var failed = 0
            for data in sources {
                guard let processed = PhotoImageProcessing.process(data) else {
                    failed += 1
                    continue
                }
                let id = UUID()
                let fileName = "Photos/\(id.uuidString).jpg"
                let thumbName = "Photos/Thumbnails/\(id.uuidString).jpg"
                do {
                    try processed.fullJPEG.write(to: root.appendingPathComponent(fileName), options: [.atomic])
                    try processed.thumbnailJPEG.write(to: root.appendingPathComponent(thumbName), options: [.atomic])
                } catch {
                    try? fm.removeItem(at: root.appendingPathComponent(fileName))
                    failed += 1
                    continue
                }
                let now = Date()
                result.append(ProjectPhoto(
                    id: id,
                    projectId: projectId,
                    albumId: defaults.albumId,
                    fileName: fileName,
                    thumbnailFileName: thumbName,
                    title: nil,
                    description: "",
                    takenDate: useCaptureTime ? now : (processed.takenDate ?? now),
                    drawingId: defaults.drawingId,
                    pageIndex: defaults.drawingId == nil ? nil : defaults.pageIndex,
                    areaId: defaults.areaId,
                    issueId: defaults.issueId,
                    pixelWidth: processed.pixelWidth,
                    pixelHeight: processed.pixelHeight,
                    byteSize: processed.fullJPEG.count,
                    syncStatus: "local_only",
                    createdDate: now,
                    updatedDate: now
                ))
            }
            return (result, failed)
        }.value

        do {
            try database.persistProjectPhotos(written.photos)
        } catch {
            removeFiles(written.photos.flatMap { [$0.fileName] + ($0.thumbnailFileName.map { [$0] } ?? []) })
            errorMessage = "Photos could not be saved: \(error.localizedDescription)"
            return []
        }
        if written.failed > 0 {
            errorMessage = written.failed == 1
                ? "1 image could not be read and was skipped."
                : "\(written.failed) images could not be read and were skipped."
        }
        reload()
        return written.photos
    }

    func importCapturedImage(_ image: UIImage, defaults: ImportDefaults = ImportDefaults()) async -> ProjectPhoto? {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            errorMessage = "The photo could not be encoded."
            return nil
        }
        return await importImages([data], useCaptureTime: true, defaults: defaults).first
    }

    // MARK: - Mutations

    @discardableResult
    func update(_ photo: ProjectPhoto) -> Bool {
        guard let database else { return false }
        var photo = photo
        let title = photo.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        photo.title = title.isEmpty ? nil : title
        photo.description = photo.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if photo.drawingId == nil {
            photo.pageIndex = nil
            photo.areaId = nil
        }
        photo.updatedDate = Date()
        do {
            try database.persistProjectPhotos([photo])
            reload()
            return true
        } catch {
            errorMessage = "Photo could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes rows first (one transaction), then removes files no row references any more.
    func delete(_ ids: [UUID]) {
        guard let database, !ids.isEmpty else { return }
        do {
            let files = try database.deleteProjectPhotos(ids: ids, projectId: projectId)
            removeFiles(files)
        } catch {
            errorMessage = "Photos could not be deleted: \(error.localizedDescription)"
        }
        reload()
    }

    func move(_ ids: [UUID], toAlbum albumId: UUID?) {
        guard let database else { return }
        do {
            try database.movePhotos(ids: ids, toAlbum: albumId, projectId: projectId)
        } catch {
            errorMessage = "Photos could not be moved: \(error.localizedDescription)"
        }
        reload()
    }

    @discardableResult
    func saveAlbum(id: UUID? = nil, name: String) -> PhotoAlbum? {
        guard let database else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if albums.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            errorMessage = "An album named “\(name)” already exists."
            return nil
        }
        var album = album(id: id) ?? PhotoAlbum(
            id: UUID(), projectId: projectId, name: name,
            sortOrder: (albums.map(\.sortOrder).max() ?? -1) + 1,
            createdDate: Date(), updatedDate: Date()
        )
        album.name = name
        album.updatedDate = Date()
        do {
            try database.persistPhotoAlbum(album)
            reload()
            return album
        } catch {
            errorMessage = "Album could not be saved: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteAlbum(_ album: PhotoAlbum) {
        guard let database else { return }
        do {
            try database.deletePhotoAlbum(id: album.id, projectId: projectId)
        } catch {
            errorMessage = "Album could not be deleted: \(error.localizedDescription)"
        }
        reload()
    }

    private func removeFiles(_ relativePaths: [String]) {
        let urls = relativePaths.map { projectRootURL.appendingPathComponent($0) }
        PhotoThumbnailCache.shared.evict(urls)
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
