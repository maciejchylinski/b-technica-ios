import SwiftUI

/// Documentation photos linked to an issue, shown on the issue screen. Uses the same
/// stored files as the gallery (no copies). Hidden when nothing is linked.
struct LinkedDocumentationPhotosSection: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var photos: PhotoDocumentationStore
    let issueId: UUID

    @State private var preview: PhotoPreviewRequest?
    @State private var editingId: UUID?

    init(userId: UUID, projectId: UUID, issueId: UUID) {
        self.issueId = issueId
        _photos = StateObject(wrappedValue: PhotoDocumentationStore(userId: userId, projectId: projectId))
    }

    private var entries: [GalleryEntry] {
        photos.photos
            .filter { $0.issueId == issueId }
            .sorted { $0.takenDate < $1.takenDate }
            .map { photo in
                GalleryEntry(
                    id: photo.id,
                    kind: .documentation,
                    fileURL: photos.fileURL(for: photo),
                    thumbnailURL: photos.thumbnailURL(for: photo),
                    title: photo.displayTitle,
                    searchText: "",
                    subtitle: photos.album(id: photo.albumId)?.name ?? "",
                    date: photo.takenDate,
                    description: photo.description
                )
            }
    }

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("None linked")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries) { entry in
                            Button {
                                preview = PhotoPreviewRequest(entries: entries, startId: entry.id)
                            } label: {
                                PhotoThumbnailCell(entry: entry)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Documentation photos")
        } footer: {
            Text("Link photos to this issue from Photo documentation. Deleting the issue keeps them.")
        }
        .onAppear { photos.reload() }
        .fullScreenCover(item: $preview) { request in
            PhotoPreviewView(
                entries: request.entries,
                startId: request.startId,
                isMissing: { !FileManager.default.fileExists(atPath: $0.fileURL.path) },
                onEdit: { id in
                    preview = nil
                    editingId = id
                },
                onDelete: { id in photos.delete([id]) },
                onClose: { preview = nil }
            )
        }
        .sheet(item: Binding(
            get: { editingId.map(IdentifiedUUID.init) },
            set: { editingId = $0?.id }
        )) { target in
            PhotoEditorSheet(photos: photos, photoId: target.id)
                .environmentObject(store)
        }
    }
}

private struct IdentifiedUUID: Identifiable {
    let id: UUID
}
