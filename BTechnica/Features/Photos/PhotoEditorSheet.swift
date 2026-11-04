import SwiftUI

/// Edit a documentation photo: title, description, date, album, and optional links to a
/// drawing (page / area) and an issue of the same project.
struct PhotoEditorSheet: View {
    @ObservedObject var photos: PhotoDocumentationStore
    @EnvironmentObject private var store: AppStore
    let photoId: UUID
    /// New photos: Cancel keeps the photo with its defaults.
    var isNew = false

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectPhoto?
    @State private var newAlbumName = ""
    @State private var showNewAlbum = false

    private var drawing: Drawing? {
        guard let id = draft?.drawingId else { return nil }
        return store.data.drawings.first { $0.id == id }
    }

    private var areaOptions: [Area] {
        guard let draft, let drawingId = draft.drawingId else { return [] }
        return store.data.areas
            .filter { $0.drawingId == drawingId && (draft.pageIndex == nil || $0.pageIndex == draft.pageIndex) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var issueOptions: [Issue] {
        store.data.issues.sorted { $0.number > $1.number }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft = Binding($draft) {
                    form(draft)
                } else {
                    ContentUnavailableView("Photo not found", systemImage: "photo")
                }
            }
            .navigationTitle(isNew ? "New photo" : "Photo details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isNew ? "Skip" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let draft, photos.update(draft) { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(draft == nil)
                }
            }
            .onAppear {
                if draft == nil { draft = photos.photo(id: photoId) }
            }
            .alert("New album", isPresented: $showNewAlbum) {
                TextField("Album name", text: $newAlbumName)
                Button("Cancel", role: .cancel) { newAlbumName = "" }
                Button("Create") {
                    if let album = photos.saveAlbum(name: newAlbumName) { draft?.albumId = album.id }
                    newAlbumName = ""
                }
            }
            .alert("Photo",
                   isPresented: Binding(get: { photos.errorMessage != nil },
                                        set: { if !$0 { photos.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(photos.errorMessage ?? "")
            }
        }
    }

    private func form(_ draft: Binding<ProjectPhoto>) -> some View {
        Form {
            Section {
                PhotoThumbnailCell(entry: GalleryEntry(
                    id: draft.wrappedValue.id,
                    kind: .documentation,
                    fileURL: photos.fileURL(for: draft.wrappedValue),
                    thumbnailURL: photos.thumbnailURL(for: draft.wrappedValue),
                    title: draft.wrappedValue.displayTitle,
                    searchText: "",
                    subtitle: "",
                    date: draft.wrappedValue.takenDate
                ))
                .frame(maxWidth: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Title", text: Binding(
                    get: { draft.wrappedValue.title ?? "" },
                    set: { draft.wrappedValue.title = $0 }
                ))
                .textInputAutocapitalization(.sentences)
                TextField("Description", text: draft.description, axis: .vertical)
                    .lineLimit(3...8)
                DatePicker("Date", selection: draft.takenDate)
            }

            Section("Album") {
                Picker("Album", selection: draft.albumId) {
                    Text("No album").tag(UUID?.none)
                    ForEach(photos.albums) { album in
                        Text(album.name).tag(UUID?.some(album.id))
                    }
                }
                Button {
                    showNewAlbum = true
                } label: {
                    Label("New album", systemImage: "folder.badge.plus")
                }
            }

            Section {
                Picker("Drawing", selection: Binding(
                    get: { draft.wrappedValue.drawingId },
                    set: { value in
                        draft.wrappedValue.drawingId = value
                        draft.wrappedValue.pageIndex = value == nil ? nil : 0
                        draft.wrappedValue.areaId = nil
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.data.drawings.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { drawing in
                        Text(drawing.name).tag(UUID?.some(drawing.id))
                    }
                }
                if let drawing, drawing.isMultiPage {
                    Stepper(
                        "Page \((draft.wrappedValue.pageIndex ?? 0) + 1) of \(drawing.pageCount)",
                        value: Binding(
                            get: { draft.wrappedValue.pageIndex ?? 0 },
                            set: { value in
                                draft.wrappedValue.pageIndex = value
                                draft.wrappedValue.areaId = nil
                            }
                        ),
                        in: 0...max(0, drawing.pageCount - 1)
                    )
                }
                if draft.wrappedValue.drawingId != nil {
                    Picker("Area", selection: draft.areaId) {
                        Text("None").tag(UUID?.none)
                        ForEach(areaOptions) { area in
                            Text(area.name).tag(UUID?.some(area.id))
                        }
                    }
                    .disabled(areaOptions.isEmpty)
                }
                Picker("Issue", selection: draft.issueId) {
                    Text("None").tag(UUID?.none)
                    ForEach(issueOptions) { issue in
                        Text("#\(issue.number) \(issue.title)").tag(UUID?.some(issue.id))
                    }
                }
            } header: {
                Text("Links (optional)")
            } footer: {
                Text("Linked photos also appear on the issue. The image file is shared, not copied.")
            }

            Section {
                if let width = draft.wrappedValue.pixelWidth, let height = draft.wrappedValue.pixelHeight {
                    LabeledContent("Size", value: "\(width) × \(height)")
                }
                if let bytes = draft.wrappedValue.byteSize {
                    LabeledContent("File", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
                LabeledContent("Storage", value: "Local only · not synced")
                if photos.isFileMissing(draft.wrappedValue) {
                    Label("The image file is missing on this device.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Create, rename and delete albums for the current project.
struct AlbumManagerView: View {
    @ObservedObject var photos: PhotoDocumentationStore
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var renaming: PhotoAlbum?
    @State private var renameText = ""
    @State private var pendingDelete: PhotoAlbum?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New album (e.g. Foundations, MEP)", text: $newName)
                            .onSubmit(create)
                        Button("Add", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(photos.albums) { album in
                        HStack {
                            Label(album.name, systemImage: "folder")
                            Spacer()
                            Text("\(photos.photos.filter { $0.albumId == album.id }.count)")
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = album } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = album.name
                                renaming = album
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                    }
                } footer: {
                    Text("Deleting an album keeps its photos; they move to Unfiled.")
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename album",
                   isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { photos.saveAlbum(id: renaming.id, name: renameText) }
                    renaming = nil
                }
            }
            .confirmationDialog(
                "Delete album “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete album", role: .destructive) {
                    if let pendingDelete { photos.deleteAlbum(pendingDelete) }
                    pendingDelete = nil
                }
            } message: {
                Text("Photos in the album are kept.")
            }
        }
    }

    private func create() {
        if photos.saveAlbum(name: newName) != nil { newName = "" }
    }
}
