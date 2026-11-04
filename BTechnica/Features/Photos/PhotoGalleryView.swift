import PhotosUI
import SwiftUI

/// Project photo documentation: camera / library import, albums, search and date filters,
/// multi-select move / delete, and a read-only view of existing issue photos.
struct PhotoGalleryView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var photos: PhotoDocumentationStore

    @State private var source: GallerySource = .documentation
    @State private var albumFilter: AlbumFilter = .all
    @State private var dateFilter: PhotoDateFilter = .any
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showLibraryPicker = false
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showCameraUnavailable = false
    @State private var showCustomRange = false
    @State private var showAlbums = false
    @State private var showMoveSheet = false
    @State private var confirmDelete = false
    @State private var preview: PhotoPreviewRequest?
    @State private var editingPhotoId: EditTarget?

    init(userId: UUID, projectId: UUID) {
        _photos = StateObject(wrappedValue: PhotoDocumentationStore(userId: userId, projectId: projectId))
    }

    // MARK: - Entries

    private var entries: [GalleryEntry] {
        let all: [GalleryEntry]
        switch source {
        case .documentation:
            all = photos.photos
                .filter { photo in
                    switch albumFilter {
                    case .all: return true
                    case .unfiled: return photo.albumId == nil
                    case .album(let id): return photo.albumId == id
                    }
                }
                .map(documentationEntry)
        case .issues:
            all = store.data.issues
                .sorted { $0.number < $1.number }
                .flatMap { issue in
                    issue.photos.map { photo in
                        GalleryEntry(
                            id: photo.id,
                            kind: .issue(issueId: issue.id),
                            fileURL: store.fileURL(for: photo),
                            thumbnailURL: nil,
                            title: "#\(issue.number) \(issue.title)",
                            searchText: [issue.title, issue.details].joined(separator: " "),
                            subtitle: "Issue photo",
                            date: photo.createdDate
                        )
                    }
                }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return all
            .filter { dateFilter.contains($0.date) }
            .filter { query.isEmpty || $0.searchText.localizedStandardContains(query) || $0.title.localizedStandardContains(query) }
            .sorted { $0.date > $1.date }
    }

    private func documentationEntry(_ photo: ProjectPhoto) -> GalleryEntry {
        let album = photos.album(id: photo.albumId)?.name
        let issue = photo.issueId.flatMap(store.issue(id:))
        let drawing = photo.drawingId.flatMap { id in store.data.drawings.first { $0.id == id } }
        let area = photo.areaId.flatMap(store.area(id:))
        return GalleryEntry(
            id: photo.id,
            kind: .documentation,
            fileURL: photos.fileURL(for: photo),
            thumbnailURL: photos.thumbnailURL(for: photo),
            title: photo.displayTitle,
            searchText: [photo.title, photo.description, album, issue?.title, drawing?.name, area?.name]
                .compactMap { $0 }.joined(separator: " "),
            subtitle: [album, drawing?.name, area?.name, issue.map { "Issue #\($0.number)" }]
                .compactMap { $0 }.joined(separator: " · "),
            date: photo.takenDate,
            description: photo.description
        )
    }

    private var sections: [(day: Date, entries: [GalleryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: $source) {
                    Text("Documentation").tag(GallerySource.documentation)
                    Text("Issue photos").tag(GallerySource.issues)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if source == .documentation {
                    albumChips
                }

                if photos.isImporting {
                    ProgressView("Importing…")
                        .frame(maxWidth: .infinity)
                }

                if entries.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    grid
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .navigationTitle("Photo documentation")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Title, description, album, issue")
        .toolbar { toolbar }
        .onChange(of: source) { _, _ in endSelection() }
        .onAppear { photos.reload() }
        .photosPicker(isPresented: $showLibraryPicker, selection: $libraryItems,
                      maxSelectionCount: 30, matching: .images)
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importLibrary(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                Task {
                    if let photo = await photos.importCapturedImage(image, defaults: importDefaults) {
                        editingPhotoId = EditTarget(id: photo.id, isNew: true)
                    }
                }
            } onCancel: {
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $preview) { request in
            PhotoPreviewView(
                entries: request.entries,
                startId: request.startId,
                isMissing: { entry in !FileManager.default.fileExists(atPath: entry.fileURL.path) },
                onEdit: { id in
                    preview = nil
                    editingPhotoId = EditTarget(id: id, isNew: false)
                },
                onDelete: { id in photos.delete([id]) },
                onClose: { preview = nil }
            )
        }
        .sheet(item: $editingPhotoId) { target in
            PhotoEditorSheet(photos: photos, photoId: target.id, isNew: target.isNew)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAlbums) {
            AlbumManagerView(photos: photos)
        }
        .sheet(isPresented: $showMoveSheet) {
            AlbumPickerSheet(photos: photos, title: "Move \(selection.count) photos") { albumId in
                photos.move(Array(selection), toAlbum: albumId)
                endSelection()
            }
        }
        .sheet(isPresented: $showCustomRange) {
            DateRangeSheet(filter: $dateFilter)
        }
        .confirmationDialog(
            selection.count == 1 ? "Delete 1 photo?" : "Delete \(selection.count) photos?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                photos.delete(Array(selection))
                endSelection()
            }
        } message: {
            Text("The photos and their local files are removed from this project. This cannot be undone.")
        }
        .alert("Camera unavailable", isPresented: $showCameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device or simulator does not have a camera. Choose Photo Library instead.")
        }
        .alert("Photos",
               isPresented: Binding(get: { photos.errorMessage != nil },
                                    set: { if !$0 { photos.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photos.errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var albumChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", count: photos.photos.count, selected: albumFilter == .all) { albumFilter = .all }
                ForEach(photos.albums) { album in
                    chip(album.name,
                         count: photos.photos.filter { $0.albumId == album.id }.count,
                         selected: albumFilter == .album(album.id)) { albumFilter = .album(album.id) }
                }
                chip("Unfiled",
                     count: photos.photos.filter { $0.albumId == nil }.count,
                     selected: albumFilter == .unfiled) { albumFilter = .unfiled }
                Button { showAlbums = true } label: {
                    Label("Albums", systemImage: "folder.badge.gearshape")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? Theme.blue : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var grid: some View {
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
            ForEach(sections, id: \.day) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.day.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(section.entries) { entry in
                            Button {
                                tap(entry)
                            } label: {
                                PhotoThumbnailCell(
                                    entry: entry,
                                    isSelecting: isSelecting,
                                    isSelected: selection.contains(entry.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: entry) }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: GalleryEntry) -> some View {
        Button { tap(entry) } label: { Label("View", systemImage: "eye") }
        if entry.kind == .documentation {
            Button { editingPhotoId = EditTarget(id: entry.id, isNew: false) } label: {
                Label("Edit details", systemImage: "pencil")
            }
            Button(role: .destructive) {
                selection = [entry.id]
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if source == .issues {
            ContentUnavailableView("No issue photos", systemImage: "exclamationmark.bubble",
                                   description: Text("Photos attached to issues appear here."))
        } else if photos.photos.isEmpty {
            ContentUnavailableView {
                Label("No photos yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Document site progress with the camera or import from your photo library. Photos stay on this device.")
            } actions: {
                Button("Take photo") { openCamera() }
                Button("Import from library") { showLibraryPicker = true }
            }
        } else {
            ContentUnavailableView("No matching photos", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Change the album or date filter."))
        }
    }

    private var selectionBar: some View {
        HStack {
            Button {
                showMoveSheet = true
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(selection.isEmpty)
            Spacer()
            Text(selection.isEmpty ? "Select photos" : "\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: Theme.touchTarget + 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Date", selection: Binding(
                    get: { dateFilter.isCustom ? PhotoDateFilter.customPlaceholder : dateFilter },
                    set: { value in
                        if value == .customPlaceholder { showCustomRange = true } else { dateFilter = value }
                    }
                )) {
                    ForEach(PhotoDateFilter.presets, id: \.self) { Text($0.title).tag($0) }
                    Text(dateFilter.isCustom ? dateFilter.title : "Custom range…").tag(PhotoDateFilter.customPlaceholder)
                }
            } label: {
                Image(systemName: dateFilter == .any ? "calendar" : "calendar.badge.clock")
            }
            .accessibilityLabel("Filter by date")
        }
        if source == .documentation {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting { endSelection() } else { isSelecting = true }
                }
                .disabled(photos.photos.isEmpty && !isSelecting)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { openCamera() } label: { Label("Take photo", systemImage: "camera") }
                    Button { showLibraryPicker = true } label: {
                        Label("Import from library", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add photos")
            }
        }
    }

    // MARK: - Actions

    private var importDefaults: PhotoDocumentationStore.ImportDefaults {
        var defaults = PhotoDocumentationStore.ImportDefaults()
        if case .album(let id) = albumFilter { defaults.albumId = id }
        return defaults
    }

    private func tap(_ entry: GalleryEntry) {
        if isSelecting {
            guard entry.kind == .documentation else { return }
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        } else {
            preview = PhotoPreviewRequest(entries: entries, startId: entry.id)
        }
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showCameraUnavailable = true
        }
    }

    private func importLibrary(_ items: [PhotosPickerItem]) async {
        libraryItems = []
        var datas: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                datas.append(data)
            }
        }
        let imported = await photos.importImages(datas, defaults: importDefaults)
        if datas.count < items.count, photos.errorMessage == nil {
            photos.errorMessage = "\(items.count - datas.count) item(s) could not be loaded from the library."
        }
        if imported.count == 1, let photo = imported.first {
            editingPhotoId = EditTarget(id: photo.id, isNew: true)
        }
    }
}

// MARK: - Models

enum GallerySource: Hashable {
    case documentation, issues
}

enum AlbumFilter: Hashable {
    case all, unfiled, album(UUID)
}

/// One cell in the gallery: a documentation photo, or a read-only issue photo.
struct GalleryEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case documentation
        case issue(issueId: UUID)
    }

    var id: UUID
    var kind: Kind
    var fileURL: URL
    /// Stored thumbnail (documentation photos); issue photos are downsampled on demand.
    var thumbnailURL: URL?
    var title: String
    var searchText: String
    var subtitle: String
    var date: Date
    var description: String = ""
}

struct PhotoPreviewRequest: Identifiable {
    var entries: [GalleryEntry]
    var startId: UUID
    var id: UUID { startId }
}

private struct EditTarget: Identifiable {
    var id: UUID
    var isNew: Bool
}

enum PhotoDateFilter: Hashable {
    case any, today, last7Days, last30Days
    case custom(from: Date, to: Date)
    /// Menu tag that opens the custom range sheet.
    case customPlaceholder

    static let presets: [PhotoDateFilter] = [.any, .today, .last7Days, .last30Days]

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .any: return "Any date"
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .custom(let from, let to):
            return "\(from.formatted(date: .abbreviated, time: .omitted)) – \(to.formatted(date: .abbreviated, time: .omitted))"
        case .customPlaceholder: return "Custom range…"
        }
    }

    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .any, .customPlaceholder: return true
        case .today: return date >= today
        case .last7Days: return date >= calendar.date(byAdding: .day, value: -6, to: today)!
        case .last30Days: return date >= calendar.date(byAdding: .day, value: -29, to: today)!
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: from)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
            return date >= start && date < end
        }
    }
}

// MARK: - Cells and sheets

struct PhotoThumbnailCell: View {
    let entry: GalleryEntry
    var isSelecting = false
    var isSelected = false

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Color(.tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if didLoad {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("File missing").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if entry.kind != .documentation {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting && entry.kind == .documentation {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.blue : .white)
                        .background(Circle().fill(isSelected ? .white : .black.opacity(0.25)))
                        .padding(6)
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().stroke(Theme.blue, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(entry.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .task(id: entry.fileURL) {
                image = await PhotoThumbnailCache.shared.load(
                    thumbnailURL: entry.thumbnailURL,
                    originalURL: entry.fileURL,
                    regenerate: entry.kind == .documentation
                )
                didLoad = true
            }
    }
}

/// Picks a target album (or "No album") for moving photos.
struct AlbumPickerSheet: View {
    @ObservedObject var photos: PhotoDocumentationStore
    let title: String
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("No album") { pick(nil) }
                    ForEach(photos.albums) { album in
                        Button(album.name) { pick(album.id) }
                    }
                }
                Section("New album") {
                    HStack {
                        TextField("Album name", text: $newAlbumName)
                        Button("Create") {
                            if let album = photos.saveAlbum(name: newAlbumName) { pick(album.id) }
                        }
                        .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ id: UUID?) {
        onPick(id)
        dismiss()
    }
}

private struct DateRangeSheet: View {
    @Binding var filter: PhotoDateFilter
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("Date range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filter = .custom(from: from, to: max(from, to))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if case .custom(let start, let end) = filter {
                    from = start
                    to = end
                }
            }
        }
        .presentationDetents([.medium])
    }
}
