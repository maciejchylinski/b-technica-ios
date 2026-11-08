import Foundation
import os.log

private let knowledgeLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "ProjectKnowledge"
)

/// Observable state for one project's document library and field notes.
///
/// One instance per open project (cached), so background indexing keeps running
/// while the user navigates around the app. Local-only: nothing here syncs yet.
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var folders: [ProjectDocumentFolder] = []
    @Published private(set) var documents: [ProjectDocument] = []
    @Published private(set) var notes: [ProjectNote] = []
    @Published private(set) var loadError: String?
    @Published private(set) var indexingProgress: [UUID: DocumentIndexer.Progress] = [:]
    @Published private(set) var isImporting = false

    let userId: UUID
    let projectId: UUID
    let projectRootURL: URL
    private let database: AppDatabase?
    private var indexingTask: Task<Void, Never>?
    private var indexingRequestedWhileRunning = false

    private static var current: KnowledgeStore?

    /// Returns the store for this project, replacing (and stopping) any other project's store.
    static func shared(userId: UUID, project: Project) -> KnowledgeStore {
        if let current, current.userId == userId, current.projectId == project.id {
            return current
        }
        current?.indexingTask?.cancel()
        let store = KnowledgeStore(userId: userId, project: project)
        current = store
        return store
    }

    #if DEBUG
    /// Demo reset: drops the cached store for `userId` (and stops its indexing) so the
    /// re-seeded library is loaded from SQLite the next time Project Documents opens.
    static func discardCachedStore(userId: UUID) {
        guard let cached = current, cached.userId == userId else { return }
        cached.indexingTask?.cancel()
        current = nil
    }
    #endif

    private init(userId: UUID, project: Project) {
        self.userId = userId
        self.projectId = project.id
        var database: AppDatabase?
        var openError: String?
        var rootURL = DocumentFileStorage.projectRootURL(
            userRootURL: AppDatabase.userRootURL(for: userId),
            projectId: project.id
        )
        do {
            let db = try AppDatabase.shared(for: userId)
            try db.ensureProject(project)
            try db.resetInterruptedIndexing(projectId: project.id)
            rootURL = DocumentFileStorage.projectRootURL(userRootURL: db.rootURL, projectId: project.id)
            database = db
        } catch {
            knowledgeLog.error("Knowledge store unavailable: \(error.localizedDescription, privacy: .public)")
            openError = "Project documents could not be loaded: \(error.localizedDescription)"
        }
        self.database = database
        self.projectRootURL = rootURL
        self.loadError = openError
        reload()
        startIndexingIfNeeded()
    }

    // MARK: Loading

    func reload() {
        guard let database else { return }
        do {
            folders = try database.fetchDocumentFolders(projectId: projectId)
            documents = try database.fetchProjectDocuments(projectId: projectId)
            notes = try database.fetchProjectNotes(projectId: projectId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func dismissLoadError() { loadError = nil }

    // MARK: Lookup

    func folder(id: UUID) -> ProjectDocumentFolder? { folders.first { $0.id == id } }
    func document(id: UUID) -> ProjectDocument? { documents.first { $0.id == id } }
    func note(id: UUID) -> ProjectNote? { notes.first { $0.id == id } }

    func folders(in parentId: UUID?) -> [ProjectDocumentFolder] {
        folders.filter { $0.parentFolderId == parentId }
    }

    func documents(in folderId: UUID?) -> [ProjectDocument] {
        documents.filter { $0.folderId == folderId }
    }

    func itemCount(inFolder id: UUID) -> Int {
        folders(in: id).count + documents(in: id).count
    }

    /// Folder ids nested anywhere under `id` (excluding `id`).
    func descendantFolderIds(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var queue = [id]
        while let next = queue.popLast() {
            for child in folders(in: next) where result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    /// Number of documents nested anywhere under a folder.
    func documentCount(inFolderTree id: UUID) -> Int {
        let tree = descendantFolderIds(of: id).union([id])
        return documents.filter { $0.folderId.map(tree.contains) ?? false }.count
    }

    func fileURL(for document: ProjectDocument) -> URL {
        DocumentFileStorage.fileURL(projectRootURL: projectRootURL, relativePath: document.fileRelativePath)
    }

    func isFileAvailable(_ document: ProjectDocument) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: document).path)
    }

    // MARK: Folders

    /// Returns an error message, or nil on success.
    func createFolder(name: String, parentId: UUID?) -> String? {
        guard let database else { return unavailableMessage }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let folder = ProjectDocumentFolder(
            id: UUID(),
            projectId: projectId,
            parentFolderId: parentId,
            name: trimmed,
            sortOrder: (folders(in: parentId).map(\.sortOrder).max() ?? -1) + 1,
            createdAt: now,
            updatedAt: now
        )
        return perform { try database.insertDocumentFolder(folder) }
    }

    func renameFolder(id: UUID, name: String) -> String? {
        guard let database else { return unavailableMessage }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return perform { try database.renameDocumentFolder(id: id, projectId: projectId, name: trimmed) }
    }

    func moveFolder(id: UUID, toParentId: UUID?) -> String? {
        guard let database else { return unavailableMessage }
        return perform { try database.moveDocumentFolder(id: id, projectId: projectId, toParentId: toParentId) }
    }

    func deleteFolder(id: UUID) -> String? {
        guard let database else { return unavailableMessage }
        return perform {
            let removed = try database.deleteDocumentFolder(id: id, projectId: projectId)
            for document in removed {
                DocumentFileStorage.removeFile(projectRootURL: projectRootURL, relativePath: document.fileRelativePath)
            }
        }
    }

    // MARK: Documents

    struct ImportSummary {
        var imported: [ProjectDocument] = []
        var duplicates: [(fileName: String, existing: String)] = []
        var failures: [(fileName: String, reason: String)] = []

        var message: String? {
            var lines: [String] = []
            for duplicate in duplicates {
                lines.append("\u{201C}\(duplicate.fileName)\u{201D} is already in the library as \u{201C}\(duplicate.existing)\u{201D}.")
            }
            for failure in failures {
                lines.append(failure.reason)
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// Copies picked PDFs into project storage (off the main thread) and queues them for indexing.
    func importDocuments(from urls: [URL], folderId: UUID?) async -> ImportSummary {
        var summary = ImportSummary()
        guard let database else {
            let message = unavailableMessage
            summary.failures = urls.map { (fileName: $0.lastPathComponent, reason: message) }
            return summary
        }
        isImporting = true
        defer { isImporting = false }

        let projectId = projectId
        let rootURL = projectRootURL
        for url in urls {
            let documentId = UUID()
            let fileName = url.lastPathComponent
            do {
                let stored = try await Task.detached(priority: .userInitiated) {
                    try DocumentFileStorage.storePDF(from: url, documentId: documentId, projectRootURL: rootURL)
                }.value

                if let existing = try database.fetchProjectDocument(projectId: projectId, checksum: stored.checksumSHA256) {
                    DocumentFileStorage.removeFile(projectRootURL: rootURL, relativePath: stored.relativePath)
                    summary.duplicates.append((fileName: fileName, existing: existing.name))
                    continue
                }

                let document = ProjectDocument.imported(
                    id: documentId,
                    projectId: projectId,
                    folderId: folderId,
                    originalFileName: fileName,
                    stored: stored
                )
                do {
                    try database.insertProjectDocument(document)
                } catch {
                    DocumentFileStorage.removeFile(projectRootURL: rootURL, relativePath: stored.relativePath)
                    throw error
                }
                summary.imported.append(document)
            } catch {
                summary.failures.append((fileName: fileName, reason: error.localizedDescription))
            }
        }
        reload()
        startIndexingIfNeeded()
        return summary
    }

    func updateDocument(
        id: UUID,
        name: String,
        category: DocumentCategory,
        descriptionText: String,
        revision: String?,
        revisionDate: Date?
    ) -> String? {
        guard let database else { return unavailableMessage }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return AppDatabase.KnowledgeError.invalidName.localizedDescription }
        let trimmedRevision = revision?.trimmingCharacters(in: .whitespacesAndNewlines)
        return perform {
            try database.updateProjectDocumentMetadata(
                id: id,
                projectId: projectId,
                name: trimmedName,
                category: category,
                descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                revision: trimmedRevision?.isEmpty == false ? trimmedRevision : nil,
                revisionDate: revisionDate
            )
        }
    }

    func moveDocument(id: UUID, toFolderId: UUID?) -> String? {
        guard let database else { return unavailableMessage }
        return perform { try database.moveProjectDocument(id: id, projectId: projectId, toFolderId: toFolderId) }
    }

    func deleteDocument(id: UUID) -> String? {
        guard let database else { return unavailableMessage }
        return perform {
            if let removed = try database.deleteProjectDocument(id: id, projectId: projectId) {
                DocumentFileStorage.removeFile(projectRootURL: projectRootURL, relativePath: removed.fileRelativePath)
            }
        }
    }

    // MARK: Indexing

    /// Re-queues a failed document, or forces a full re-extraction.
    func retryIndexing(id: UUID, force: Bool = false) {
        guard let database else { return }
        _ = perform { try database.requestDocumentIndexing(id: id, projectId: projectId, force: force) }
        startIndexingIfNeeded()
    }

    /// Processes pending documents one by one on a background task.
    func startIndexingIfNeeded() {
        guard let database else { return }
        guard indexingTask == nil else {
            indexingRequestedWhileRunning = true
            return
        }
        let projectId = projectId
        let rootURL = projectRootURL
        indexingTask = Task.detached(priority: .utility) { [self] in
            var attempted = Set<UUID>()
            while !Task.isCancelled {
                let queue = (try? database.fetchDocumentsNeedingIndex(
                    projectId: projectId,
                    extractorVersion: DocumentTextExtractor.version
                )) ?? []
                guard let next = queue.first(where: { !attempted.contains($0.id) }) else { break }
                attempted.insert(next.id)

                let outcome = DocumentIndexer.index(
                    documentId: next.id,
                    projectId: projectId,
                    database: database,
                    projectRootURL: rootURL,
                    onProgress: { progress in
                        Task { @MainActor in self.indexingProgress[progress.documentId] = progress }
                    }
                )
                knowledgeLog.info("Indexed \(next.id.uuidString, privacy: .public): \(String(describing: outcome), privacy: .public)")
                await self.finishIndexing(next.id)
            }
            await self.indexingQueueDrained()
        }
    }

    private func finishIndexing(_ id: UUID) {
        indexingProgress[id] = nil
        reload()
    }

    private func indexingQueueDrained() {
        indexingTask = nil
        indexingProgress = [:]
        reload()
        if indexingRequestedWhileRunning {
            indexingRequestedWhileRunning = false
            startIndexingIfNeeded()
        }
    }

    // MARK: Notes

    @discardableResult
    func saveNote(id: UUID?, title: String, body: String, category: NoteCategory?) -> Result<ProjectNote, KnowledgeStoreError> {
        guard let database else { return .failure(KnowledgeStoreError(message: unavailableMessage)) }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            return .failure(KnowledgeStoreError(message: "Add a title or some text."))
        }
        let now = Date()
        let existing = id.flatMap(note(id:))
        let note = ProjectNote(
            id: existing?.id ?? id ?? UUID(),
            projectId: projectId,
            title: trimmedTitle,
            body: trimmedBody,
            category: category,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        if let message = perform({ try database.upsertProjectNote(note) }) {
            return .failure(KnowledgeStoreError(message: message))
        }
        return .success(note)
    }

    func deleteNote(id: UUID) -> String? {
        guard let database else { return unavailableMessage }
        return perform { try database.deleteProjectNote(id: id, projectId: projectId) }
    }

    // MARK: Search

    func search(_ query: String, scope: KnowledgeSearchScope) async -> Result<[KnowledgeSearchResult], KnowledgeStoreError> {
        guard let database else { return .failure(KnowledgeStoreError(message: unavailableMessage)) }
        let projectId = projectId
        return await Task.detached(priority: .userInitiated) { () -> Result<[KnowledgeSearchResult], KnowledgeStoreError> in
            do {
                return .success(try database.searchKnowledge(projectId: projectId, query: query, scope: scope))
            } catch {
                return .failure(KnowledgeStoreError(message: error.localizedDescription))
            }
        }.value
    }

    // MARK: Helpers

    private var unavailableMessage: String { "Local storage is unavailable." }

    private func perform(_ work: () throws -> Void) -> String? {
        do {
            try work()
            reload()
            return nil
        } catch {
            reload()
            return error.localizedDescription
        }
    }
}

struct KnowledgeStoreError: Error, Sendable {
    var message: String
}
