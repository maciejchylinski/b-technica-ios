import SwiftUI

private enum DrawingsNav: Hashable {
    case folder(UUID)
    case drawing(UUID)
}

/// The Drawings tab: nested folders plus imported PDF drawings for the active project.
struct DrawingsListView: View {
    @EnvironmentObject private var store: AppStore

    @State private var path: [DrawingsNav] = []
    @State private var showingPicker = false
    @State private var showSamplePicker = false
    @State private var importError: String?
    @State private var multiPageNotice: String?
    @State private var detailsDrawingId: UUID?
    @State private var pendingEditorId: UUID?
    @State private var pendingDelete: PendingDrawingDelete?
    @State private var folderNamePrompt: FolderNamePrompt?
    @State private var folderActionError: String?
    @State private var movingDrawingId: UUID?

    /// Folder currently being browsed (`nil` = project root).
    private var currentFolderId: UUID? {
        for item in path.reversed() {
            if case .folder(let id) = item { return id }
        }
        return nil
    }

    private var isProjectTotallyEmpty: Bool {
        store.data.drawings.isEmpty && store.data.drawingFolders.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            folderBrowser(title: "Drawings", folderId: nil)
                .navigationDestination(for: DrawingsNav.self) { nav in
                    switch nav {
                    case .folder(let id):
                        folderBrowser(
                            title: store.folder(id: id)?.name ?? "Folder",
                            folderId: id
                        )
                    case .drawing(let id):
                        if store.data.drawings.contains(where: { $0.id == id }) {
                            DrawingDetailView(drawingId: id)
                        } else {
                            ContentUnavailableView("Drawing unavailable", systemImage: "doc.richtext")
                        }
                    }
                }
        }
        .sheet(isPresented: $showingPicker, onDismiss: presentPendingEditor) {
            PDFDocumentPicker { url in
                handlePicked(url)
                showingPicker = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSamplePicker) {
            SampleDrawingsSheet { sample in
                importSample(sample)
            }
        }
        .sheet(isPresented: Binding(
            get: { detailsDrawingId != nil },
            set: { if !$0 { detailsDrawingId = nil } }
        )) {
            if let detailsDrawingId {
                DrawingDetailsEditor(drawingId: detailsDrawingId)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: Binding(
            get: { movingDrawingId != nil },
            set: { if !$0 { movingDrawingId = nil } }
        )) {
            if let movingDrawingId {
                MoveDrawingSheet(drawingId: movingDrawingId) {
                    self.movingDrawingId = nil
                }
                .environmentObject(store)
            }
        }
        .alert("Import failed",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(DrawingImportNotice.multiPageTitle,
               isPresented: Binding(get: { multiPageNotice != nil },
                                    set: { if !$0 { multiPageNotice = nil } })) {
            Button("OK", role: .cancel) { multiPageNotice = nil }
        } message: {
            Text(multiPageNotice ?? "")
        }
        .alert("Delete drawing?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete drawing and issues", role: .destructive) {
                confirmDeleteWithIssues()
            }
        } message: {
            Text(pendingDelete?.message ?? "")
        }
        .alert(
            folderNamePrompt?.title ?? "Folder",
            isPresented: Binding(
                get: { folderNamePrompt != nil },
                set: { if !$0 { folderNamePrompt = nil } }
            )
        ) {
            TextField("Folder name", text: Binding(
                get: { folderNamePrompt?.name ?? "" },
                set: { newValue in
                    guard var prompt = folderNamePrompt else { return }
                    prompt.name = newValue
                    folderNamePrompt = prompt
                }
            ))
            Button("Cancel", role: .cancel) { folderNamePrompt = nil }
            Button(folderNamePrompt?.confirmTitle ?? "Save") {
                commitFolderNamePrompt()
            }
        } message: {
            Text(folderNamePrompt?.message ?? "")
        }
        .alert("Folder",
               isPresented: Binding(get: { folderActionError != nil },
                                    set: { if !$0 { folderActionError = nil } })) {
            Button("OK", role: .cancel) { folderActionError = nil }
        } message: {
            Text(folderActionError ?? "")
        }
    }

    @ViewBuilder
    private func folderBrowser(title: String, folderId: UUID?) -> some View {
        let folders = store.folders(in: folderId)
        let drawings = store.drawings(in: folderId)
        let showProjectEmpty = folderId == nil && isProjectTotallyEmpty

        Group {
            if showProjectEmpty {
                emptyState
            } else if folders.isEmpty && drawings.isEmpty {
                emptyFolderState
            } else {
                List {
                    if !folders.isEmpty {
                        Section("Folders") {
                            ForEach(folders) { folder in
                                NavigationLink(value: DrawingsNav.folder(folder.id)) {
                                    FolderRow(folder: folder, isEmpty: store.isFolderEmpty(folder.id))
                                }
                                .accessibilityIdentifier("folderRow")
                                .accessibilityLabel(folder.name)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        requestDeleteFolder(folder)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                    Button {
                                        folderNamePrompt = .rename(folder)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(Theme.blue)
                                }
                                .contextMenu {
                                    Button {
                                        folderNamePrompt = .rename(folder)
                                    } label: {
                                        Label("Rename folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        requestDeleteFolder(folder)
                                    } label: {
                                        Label("Delete folder", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !drawings.isEmpty {
                        Section("Drawings") {
                            ForEach(drawings) { drawing in
                                NavigationLink(value: DrawingsNav.drawing(drawing.id)) {
                                    DrawingRow(drawing: drawing)
                                }
                                .accessibilityIdentifier("drawingRow")
                                .accessibilityLabel(drawing.name)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        requestDelete(drawing)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                    Button {
                                        detailsDrawingId = drawing.id
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(Theme.blue)
                                    Button {
                                        movingDrawingId = drawing.id
                                    } label: {
                                        Label("Move", systemImage: "folder")
                                    }
                                    .tint(.orange)
                                }
                                .contextMenu {
                                    Button {
                                        detailsDrawingId = drawing.id
                                    } label: {
                                        Label("Edit drawing details", systemImage: "pencil")
                                    }
                                    Button {
                                        movingDrawingId = drawing.id
                                    } label: {
                                        Label("Move to folder…", systemImage: "folder")
                                    }
                                    Button(role: .destructive) {
                                        requestDelete(drawing)
                                    } label: {
                                        Label("Delete drawing", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        folderNamePrompt = .create(parentFolderId: folderId)
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Import PDF", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showSamplePicker = true
                    } label: {
                        Label("Add sample drawing", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No drawings yet", systemImage: "doc.richtext")
        } description: {
            Text("Create a folder or import a PDF drawing from Files. You can also add a sample floor plan.")
        } actions: {
            Button {
                folderNamePrompt = .create(parentFolderId: nil)
            } label: {
                Text("New Folder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            Button {
                showingPicker = true
            } label: {
                Text("Import PDF")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
            Button {
                showSamplePicker = true
            } label: {
                Text("Add sample drawing")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
        }
    }

    private var emptyFolderState: some View {
        ContentUnavailableView {
            Label("Empty folder", systemImage: "folder")
        } description: {
            Text("Add a subfolder or import a drawing into this folder.")
        } actions: {
            Button {
                folderNamePrompt = .create(parentFolderId: currentFolderId)
            } label: {
                Text("New Folder")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            Button {
                showingPicker = true
            } label: {
                Text("Import PDF")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
        }
    }

    private func handlePicked(_ url: URL) {
        let destination = currentFolderId
        Task { @MainActor in
            do {
                let drawing = try await store.importDrawing(from: url, folderId: destination)
                noteMultiPageIfNeeded(drawing)
                pendingEditorId = drawing.id
                presentPendingEditor()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importSample(_ sample: SampleDrawing) {
        let destination = currentFolderId
        Task { @MainActor in
            do {
                let drawing = try await store.importSampleDrawing(sample, folderId: destination)
                noteMultiPageIfNeeded(drawing)
                pendingEditorId = drawing.id
                presentPendingEditor()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func noteMultiPageIfNeeded(_ drawing: Drawing) {
        if drawing.isMultiPage {
            multiPageNotice = DrawingImportNotice.multiPageMessage
        }
    }

    private func presentPendingEditor() {
        guard let id = pendingEditorId else { return }
        pendingEditorId = nil
        DispatchQueue.main.async {
            detailsDrawingId = id
        }
    }

    private func requestDelete(_ drawing: Drawing) {
        let issueCount = store.issues(for: drawing).count
        if issueCount > 0 {
            pendingDelete = PendingDrawingDelete(drawing: drawing, issueCount: issueCount)
        } else {
            _ = store.deleteDrawing(drawing)
        }
    }

    private func confirmDeleteWithIssues() {
        guard let pendingDelete else { return }
        _ = store.deleteDrawing(pendingDelete.drawing, confirmingIssueDeletion: true)
        self.pendingDelete = nil
    }

    private func requestDeleteFolder(_ folder: DrawingFolder) {
        if let reason = store.deleteFolder(id: folder.id) {
            folderActionError = reason
        }
    }

    private func commitFolderNamePrompt() {
        guard let prompt = folderNamePrompt else { return }
        switch prompt.mode {
        case .create(let parentId):
            if store.createFolder(name: prompt.name, parentFolderId: parentId) == nil {
                folderActionError = "Enter a unique folder name."
            }
        case .rename(let folderId):
            if let reason = store.renameFolder(id: folderId, name: prompt.name) {
                folderActionError = reason
            }
        }
        folderNamePrompt = nil
    }
}

private struct FolderNamePrompt: Identifiable {
    enum Mode {
        case create(parentFolderId: UUID?)
        case rename(folderId: UUID)
    }

    let id = UUID()
    var mode: Mode
    var name: String

    var title: String {
        switch mode {
        case .create: return "New Folder"
        case .rename: return "Rename Folder"
        }
    }

    var confirmTitle: String {
        switch mode {
        case .create: return "Create"
        case .rename: return "Save"
        }
    }

    var message: String {
        "Folder names are your own — use whatever helps you organize drawings."
    }

    static func create(parentFolderId: UUID?) -> FolderNamePrompt {
        FolderNamePrompt(mode: .create(parentFolderId: parentFolderId), name: "")
    }

    static func rename(_ folder: DrawingFolder) -> FolderNamePrompt {
        FolderNamePrompt(mode: .rename(folderId: folder.id), name: folder.name)
    }
}

private struct PendingDrawingDelete {
    let drawing: Drawing
    let issueCount: Int

    var message: String {
        let noun = issueCount == 1 ? "issue" : "issues"
        return "This drawing has \(issueCount) \(noun). Deleting it also deletes those \(noun) and their photos. This cannot be undone."
    }
}

private struct FolderRow: View {
    let folder: DrawingFolder
    let isEmpty: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(isEmpty ? "Empty" : "Contains items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// One row in the drawings list, showing name, optional metadata and scale status.
private struct DrawingRow: View {
    let drawing: Drawing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(drawing.name)
                    .font(.headline)
                    .lineLimit(2)

                if let revision = drawing.displayRevision {
                    Text("Rev \(revision)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let discipline = drawing.displayDiscipline {
                    Text(discipline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let location = drawing.displayLocation {
                    Text(location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(drawing.calibrationStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct FolderMoveDestination: Identifiable {
    let id: String
    let folderId: UUID?
    let title: String
    let depth: Int
}

/// Picks a destination folder (or project root) for a drawing move.
private struct MoveDrawingSheet: View {
    @EnvironmentObject private var store: AppStore
    let drawingId: UUID
    let onDone: () -> Void

    @State private var errorMessage: String?

    private var drawing: Drawing? {
        store.data.drawings.first { $0.id == drawingId }
    }

    private var destinations: [FolderMoveDestination] {
        var rows: [FolderMoveDestination] = [
            FolderMoveDestination(id: "root", folderId: nil, title: "Project root", depth: 0)
        ]
        func walk(parent: UUID?, depth: Int) {
            for folder in store.folders(in: parent) {
                rows.append(
                    FolderMoveDestination(
                        id: folder.id.uuidString,
                        folderId: folder.id,
                        title: folder.name,
                        depth: depth
                    )
                )
                walk(parent: folder.id, depth: depth + 1)
            }
        }
        walk(parent: nil, depth: 1)
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(destinations) { dest in
                    Button {
                        move(to: dest.folderId)
                    } label: {
                        HStack(spacing: 8) {
                            Text(dest.title)
                                .foregroundStyle(.primary)
                                .padding(.leading, CGFloat(dest.depth) * 16)
                            Spacer()
                            if drawing?.folderId == dest.folderId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
            .alert("Could not move",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to folderId: UUID?) {
        if let reason = store.moveDrawing(id: drawingId, toFolderId: folderId) {
            errorMessage = reason
            return
        }
        onDone()
    }
}

#Preview {
    DrawingsListView().environmentObject(AppStore())
}
