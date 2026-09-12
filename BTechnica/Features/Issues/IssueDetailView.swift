import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Full issue detail screen opened from a pin preview or the Issues list.
struct IssueDetailView: View {
    @EnvironmentObject private var store: AppStore
    let issueId: UUID

    @State private var showAddPhotoOptions = false
    @State private var showCamera = false
    @State private var showCameraUnavailable = false
    @State private var showLibraryPicker = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var previewPhoto: IssuePhoto?

    private var issue: Issue? {
        store.issue(id: issueId)
    }

    private var drawing: Drawing? {
        guard let issue else { return nil }
        return store.data.drawings.first { $0.id == issue.drawingId }
    }

    private var drawingName: String {
        drawing?.name ?? "Unknown drawing"
    }

    var body: some View {
        Group {
            if let issue {
                List {
                    Section {
                        LabeledContent("Number", value: "#\(issue.number)")
                        LabeledContent("Status", value: issue.status.label)
                        LabeledContent("Drawing", value: drawingName)
                        if let revision = drawing?.displayRevision {
                            LabeledContent("Revision", value: revision)
                        }
                        if let location = drawing?.displayLocation {
                            LabeledContent("Location", value: location)
                        }
                        LabeledContent("Page", value: "\(issue.pageIndex + 1)")
                    }

                    Section("Details") {
                        Text(issue.title)
                            .font(.headline)
                        if issue.details.isEmpty {
                            Text("No description")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(issue.details)
                        }
                    }

                    photosSection(issue)

                    if issue.discipline != nil || issue.contractor != nil {
                        Section("Classification") {
                            if let discipline = issue.discipline, !discipline.isEmpty {
                                LabeledContent("Discipline", value: discipline)
                            }
                            if let contractor = issue.contractor, !contractor.isEmpty {
                                LabeledContent("Contractor", value: contractor)
                            }
                        }
                    }

                    Section {
                        LabeledContent("Created", value: issue.createdDate.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .navigationTitle(issue.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Issue unavailable",
                                       systemImage: "exclamationmark.bubble")
            }
        }
        .confirmationDialog("Add photo", isPresented: $showAddPhotoOptions, titleVisibility: .visible) {
            Button("Camera") { openCamera() }
            Button("Photo Library") { showLibraryPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibraryPicker,
                      selection: $libraryItem,
                      matching: .images)
        .onChange(of: libraryItem) { _, newItem in
            Task { await importLibraryPhoto(newItem) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                store.addPhoto(from: image, to: issueId)
            } onCancel: {
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $previewPhoto) { photo in
            IssuePhotoPreviewView(image: store.image(for: photo)) {
                previewPhoto = nil
            }
        }
        .alert("Camera unavailable", isPresented: $showCameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device or simulator does not have a camera. Choose Photo Library instead.")
        }
    }

    @ViewBuilder
    private func photosSection(_ issue: Issue) -> some View {
        Section("Photos") {
            if issue.photos.isEmpty {
                Text("No photos yet")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(issue.photos) { photo in
                            Button {
                                previewPhoto = photo
                            } label: {
                                IssuePhotoThumbnail(image: store.image(for: photo))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Button {
                showAddPhotoOptions = true
            } label: {
                Label("Add photo", systemImage: "photo.badge.plus")
            }
        }
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showCameraUnavailable = true
        }
    }

    private func importLibraryPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { libraryItem = nil }
        do {
            let picked = try await item.loadTransferable(type: PickedImage.self)
            guard let image = picked?.image else { return }
            store.addPhoto(from: image, to: issueId)
        } catch {
            print("[IssueDetail] Failed to import library photo: \(error)")
        }
    }
}

/// Loads a UIImage from a PhotosPicker selection.
private struct PickedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return PickedImage(image: image)
        }
    }
}

private struct IssuePhotoThumbnail: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: 72, height: 72)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(image == nil ? "Missing photo" : "Issue photo")
    }
}

/// Simple full-screen photo viewer. Missing files show a placeholder.
private struct IssuePhotoPreviewView: View {
    let image: UIImage?
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Photo unavailable",
                                           systemImage: "photo")
                    .foregroundStyle(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

#Preview {
    NavigationStack {
        IssueDetailView(issueId: UUID())
            .environmentObject(AppStore())
    }
}
