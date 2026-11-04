import SwiftUI

/// One level of the project document library (`folderId == nil` is the library root).
struct DocumentFolderView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let folderId: UUID?

    @State private var showingPicker = false
    @State private var namePrompt: KnowledgeNamePrompt?
    @State private var errorMessage: String?
    @State private var importNotice: String?
    @State private var infoDocumentId: UUID?
    @State private var moveTarget: KnowledgeMoveTarget?
    @State private var pendingDelete: KnowledgePendingDelete?

    private var subfolders: [ProjectDocumentFolder] { knowledge.folders(in: folderId) }
    private var documents: [ProjectDocument] { knowledge.documents(in: folderId) }

    private var title: String {
        folderId.flatMap { knowledge.folder(id: $0)?.name } ?? "Project Documents"
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Import PDF", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            namePrompt = .createFolder(parentId: folderId)
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        if knowledge.isImporting {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(knowledge.isImporting)
                    .accessibilityLabel("Add document")
                    .accessibilityIdentifier("knowledgeAddMenu")
                }
            }
            .modifier(FolderTitleModifier(title: title, isRoot: folderId == nil))
            .sheet(isPresented: $showingPicker) {
                MultiPDFDocumentPicker { urls in
                    showingPicker = false
                    importPicked(urls)
                }
                .ignoresSafeArea()
            }
            .sheet(item: Binding(
                get: { infoDocumentId.map(IdentifiedUUID.init) },
                set: { infoDocumentId = $0?.id }
            )) { item in
                NavigationStack {
                    DocumentInfoView(knowledge: knowledge, documentId: item.id, showsDoneButton: true)
                }
            }
            .sheet(item: $moveTarget) { target in
                KnowledgeMoveSheet(knowledge: knowledge, target: target) {
                    moveTarget = nil
                }
            }
            .alert(
                namePrompt?.title ?? "",
                isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })
            ) {
                TextField("Name", text: Binding(
                    get: { namePrompt?.name ?? "" },
                    set: { namePrompt?.name = $0 }
                ))
                Button("Cancel", role: .cancel) { namePrompt = nil }
                Button(namePrompt?.confirmTitle ?? "Save") { commitNamePrompt() }
            }
            .alert(
                "Project Documents",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                "Import",
                isPresented: Binding(get: { importNotice != nil }, set: { if !$0 { importNotice = nil } })
            ) {
                Button("OK", role: .cancel) { importNotice = nil }
            } message: {
                Text(importNotice ?? "")
            }
            .confirmationDialog(
                pendingDelete?.title ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                Button(item.confirmTitle, role: .destructive) { confirmDelete(item) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(item.message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if subfolders.isEmpty && documents.isEmpty {
            emptyState
        } else {
            List {
                if folderId == nil, !knowledge.indexingProgress.isEmpty || pendingCount > 0 {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(indexingSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !subfolders.isEmpty {
                    Section("Folders") {
                        ForEach(subfolders) { folder in
                            NavigationLink(value: KnowledgeRoute.folder(folder.id)) {
                                KnowledgeFolderRow(folder: folder, itemCount: knowledge.itemCount(inFolder: folder.id))
                            }
                            .accessibilityIdentifier("knowledgeFolderRow")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    requestDelete(folder: folder)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                                Button {
                                    namePrompt = .renameFolder(folder)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.blue)
                                Button {
                                    moveTarget = .folder(folder.id)
                                } label: {
                                    Label("Move", systemImage: "folder")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button {
                                    namePrompt = .renameFolder(folder)
                                } label: {
                                    Label("Rename folder", systemImage: "pencil")
                                }
                                Button {
                                    moveTarget = .folder(folder.id)
                                } label: {
                                    Label("Move folder…", systemImage: "folder")
                                }
                                Button(role: .destructive) {
                                    requestDelete(folder: folder)
                                } label: {
                                    Label("Delete folder", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !documents.isEmpty {
                    Section("Documents") {
                        ForEach(documents) { document in
                            NavigationLink(value: KnowledgeRoute.document(document.id, pageIndex: nil, highlight: [])) {
                                ProjectDocumentRow(
                                    document: document,
                                    progress: knowledge.indexingProgress[document.id],
                                    fileAvailable: knowledge.isFileAvailable(document)
                                )
                            }
                            .accessibilityIdentifier("knowledgeDocumentRow")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = .document(document)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                                Button {
                                    infoDocumentId = document.id
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Theme.blue)
                                Button {
                                    moveTarget = .document(document.id)
                                } label: {
                                    Label("Move", systemImage: "folder")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button {
                                    infoDocumentId = document.id
                                } label: {
                                    Label("Edit details", systemImage: "pencil")
                                }
                                Button {
                                    moveTarget = .document(document.id)
                                } label: {
                                    Label("Move to folder…", systemImage: "folder")
                                }
                                if document.indexStatus == .failed {
                                    Button {
                                        knowledge.retryIndexing(id: document.id)
                                    } label: {
                                        Label("Retry indexing", systemImage: "arrow.clockwise")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingDelete = .document(document)
                                } label: {
                                    Label("Delete document", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var pendingCount: Int {
        knowledge.documents.filter { $0.indexStatus == .pending || $0.indexStatus == .indexing }.count
    }

    private var indexingSummary: String {
        let count = max(pendingCount, knowledge.indexingProgress.count)
        return count == 1
            ? "Indexing 1 document for search…"
            : "Indexing \(count) documents for search…"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(folderId == nil ? "No documents yet" : "Empty folder", systemImage: folderId == nil ? "books.vertical" : "folder")
        } description: {
            Text(folderId == nil
                 ? "Import specifications, manuals and approvals as PDF from Files. Their text becomes searchable offline."
                 : "Import a PDF or add a subfolder.")
        } actions: {
            Button {
                showingPicker = true
            } label: {
                Text("Import PDF")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .accessibilityIdentifier("knowledgeImportButton")
            Button {
                namePrompt = .createFolder(parentId: folderId)
            } label: {
                Text("New Folder")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
        }
    }

    // MARK: Actions

    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let destination = folderId
        Task { @MainActor in
            let summary = await knowledge.importDocuments(from: urls, folderId: destination)
            MultiPDFDocumentPicker.discardTemporaryCopies(urls)
            if let message = summary.message {
                importNotice = message
            } else if summary.imported.count == 1, let document = summary.imported.first {
                // Single import: let the engineer set category / description right away.
                infoDocumentId = document.id
            }
        }
    }

    private func requestDelete(folder: ProjectDocumentFolder) {
        let documentCount = knowledge.documentCount(inFolderTree: folder.id)
        let folderCount = knowledge.descendantFolderIds(of: folder.id).count
        if documentCount == 0 && folderCount == 0 {
            if let message = knowledge.deleteFolder(id: folder.id) { errorMessage = message }
        } else {
            pendingDelete = .folder(folder, documentCount: documentCount, subfolderCount: folderCount)
        }
    }

    private func confirmDelete(_ item: KnowledgePendingDelete) {
        pendingDelete = nil
        let message: String?
        switch item {
        case .folder(let folder, _, _):
            message = knowledge.deleteFolder(id: folder.id)
        case .document(let document):
            message = knowledge.deleteDocument(id: document.id)
        }
        if let message { errorMessage = message }
    }

    private func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        let message: String?
        switch prompt.mode {
        case .createFolder(let parentId):
            message = knowledge.createFolder(name: prompt.name, parentId: parentId)
        case .renameFolder(let id):
            message = knowledge.renameFolder(id: id, name: prompt.name)
        }
        if let message { errorMessage = message }
    }
}

private struct FolderTitleModifier: ViewModifier {
    let title: String
    let isRoot: Bool

    func body(content: Content) -> some View {
        if isRoot {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

private struct KnowledgeNamePrompt {
    enum Mode {
        case createFolder(parentId: UUID?)
        case renameFolder(UUID)
    }

    var mode: Mode
    var name: String

    var title: String {
        switch mode {
        case .createFolder: return "New Folder"
        case .renameFolder: return "Rename Folder"
        }
    }

    var confirmTitle: String {
        switch mode {
        case .createFolder: return "Create"
        case .renameFolder: return "Save"
        }
    }

    static func createFolder(parentId: UUID?) -> KnowledgeNamePrompt {
        KnowledgeNamePrompt(mode: .createFolder(parentId: parentId), name: "")
    }

    static func renameFolder(_ folder: ProjectDocumentFolder) -> KnowledgeNamePrompt {
        KnowledgeNamePrompt(mode: .renameFolder(folder.id), name: folder.name)
    }
}

private enum KnowledgePendingDelete {
    case folder(ProjectDocumentFolder, documentCount: Int, subfolderCount: Int)
    case document(ProjectDocument)

    var title: String {
        switch self {
        case .folder(let folder, _, _): return "Delete \u{201C}\(folder.name)\u{201D}?"
        case .document(let document): return "Delete \u{201C}\(document.name)\u{201D}?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .folder: return "Delete folder and contents"
        case .document: return "Delete document"
        }
    }

    var message: String {
        switch self {
        case .folder(_, let documentCount, let subfolderCount):
            var parts: [String] = []
            if documentCount > 0 { parts.append(documentCount == 1 ? "1 document" : "\(documentCount) documents") }
            if subfolderCount > 0 { parts.append(subfolderCount == 1 ? "1 subfolder" : "\(subfolderCount) subfolders") }
            return "This also deletes \(parts.joined(separator: " and ")) from this device. This cannot be undone."
        case .document:
            return "The PDF and its search index are removed from this device. This cannot be undone."
        }
    }
}

private struct KnowledgeFolderRow: View {
    let folder: ProjectDocumentFolder
    let itemCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(itemCount == 0 ? "Empty" : (itemCount == 1 ? "1 item" : "\(itemCount) items"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDocumentRow: View {
    let document: ProjectDocument
    let progress: DocumentIndexer.Progress?
    let fileAvailable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: document.category.systemImage)
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !document.descriptionText.isEmpty {
                    Text(document.descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DocumentIndexBadge(document: document, progress: progress, fileAvailable: fileAvailable)
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var metadataLine: String {
        var parts = [document.category.title]
        if let revision = document.displayRevision { parts.append("Rev \(revision)") }
        parts.append(KnowledgeFormat.pages(document.pageCount))
        parts.append(KnowledgeFormat.fileSize(document.fileSizeBytes))
        return parts.joined(separator: " · ")
    }
}

enum KnowledgeMoveTarget: Identifiable {
    case document(UUID)
    case folder(UUID)

    var id: String {
        switch self {
        case .document(let id): return "doc-\(id.uuidString)"
        case .folder(let id): return "folder-\(id.uuidString)"
        }
    }
}

/// Destination picker for moving a document or folder within the library.
struct KnowledgeMoveSheet: View {
    @ObservedObject var knowledge: KnowledgeStore
    let target: KnowledgeMoveTarget
    let onDone: () -> Void

    @State private var errorMessage: String?

    private struct Destination: Identifiable {
        let id: String
        let folderId: UUID?
        let title: String
        let depth: Int
    }

    private var currentParent: UUID? {
        switch target {
        case .document(let id): return knowledge.document(id: id)?.folderId
        case .folder(let id): return knowledge.folder(id: id)?.parentFolderId
        }
    }

    private var excluded: Set<UUID> {
        guard case .folder(let id) = target else { return [] }
        return knowledge.descendantFolderIds(of: id).union([id])
    }

    private var destinations: [Destination] {
        var rows = [Destination(id: "root", folderId: nil, title: "Library root", depth: 0)]
        let blocked = excluded
        func walk(_ parent: UUID?, depth: Int) {
            for folder in knowledge.folders(in: parent) where !blocked.contains(folder.id) {
                rows.append(Destination(id: folder.id.uuidString, folderId: folder.id, title: folder.name, depth: depth))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 1)
        return rows
    }

    var body: some View {
        NavigationStack {
            List(destinations) { destination in
                Button {
                    move(to: destination.folderId)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.folderId == nil ? "books.vertical" : "folder")
                            .foregroundStyle(Theme.blue)
                        Text(destination.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if currentParent == destination.folderId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.blue)
                        }
                    }
                    .padding(.leading, CGFloat(destination.depth) * 16)
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
            .alert(
                "Could not move",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to folderId: UUID?) {
        let message: String?
        switch target {
        case .document(let id): message = knowledge.moveDocument(id: id, toFolderId: folderId)
        case .folder(let id): message = knowledge.moveFolder(id: id, toParentId: folderId)
        }
        if let message {
            errorMessage = message
        } else {
            onDone()
        }
    }
}
