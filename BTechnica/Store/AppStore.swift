import Foundation
import PDFKit
import SwiftUI
import UIKit

/// Central observable store for one local project workspace.
///
/// Responsibilities:
///  - own in-memory `AppData` and publish changes to SwiftUI,
///  - persist drawing folders, drawings, issues, areas, and issue photo metadata in SQLite
///    (authoritative after import),
///  - persist user-global contractors/equipment/disciplines in SQLite (authoritative after import);
///    `Users/<userId>/userdata.json` stays a frozen recovery snapshot,
///  - manage on-disk PDF and issue photo files for this project only.
///
/// Cloud project rows live in Supabase; this store is local-only (not synced yet).
/// Legacy `Documents/appdata.json` and `Users/<userId>/appdata.json` are never
/// auto-assigned into a cloud project workspace.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData
    /// User-visible local storage problem (load or save). Cleared on successful save.
    @Published private(set) var storageError: String?
    /// Drawing ids with an in-flight on-demand PDF download.
    @Published private(set) var pdfDownloadInFlight: Set<UUID> = []
    /// Last download error per drawing id (cleared on success / new attempt).
    @Published private(set) var pdfDownloadErrors: [UUID: String] = [:]

    /// Authenticated account that owns this local workspace.
    let userId: UUID
    /// Cloud project id this local workspace is bound to.
    let projectId: UUID

    private let fileManager = FileManager.default
    /// When true, the on-disk project `appdata.json` is corrupt/untrusted — do not promote it to last-good.
    private var storeFileUntrusted = false
    /// Per-user SQLite database; project content entities read and write here when non-nil.
    private var database: AppDatabase?
    /// When true, JSON `drawingFolders` / `drawings` are recovery-only (not rewritten from memory).
    private var drawingsUseSQLite = false
    /// When true, JSON `issues` / `areas` (incl. embedded photos) are recovery-only.
    private var issuesAreasUseSQLite = false
    /// When true, JSON contractors / equipment / disciplines are recovery-only.
    private var userSharedUseSQLite = false
    /// Entity state last loaded from or successfully written to SQLite. `persist()` writes
    /// only the difference against it instead of re-upserting the whole project graph.
    /// `nil` falls back to the full-graph write.
    private var sqliteBaseline: SQLiteWorkspaceBaseline?
    /// Project identity last written to the residual JSON files while every entity array
    /// there is frozen; an unchanged key means the JSON rewrite would be byte-identical.
    private var lastFrozenJSONKey: FrozenJSONKey?

    /// Documents/Users/<userId>/Projects/<projectId>/appdata.json
    private var storeURL: URL {
        projectRootURL.appendingPathComponent("appdata.json")
    }

    /// Documents/Users/<userId>/Projects/<projectId>/appdata-last-good.json
    private var lastGoodURL: URL {
        projectRootURL.appendingPathComponent("appdata-last-good.json")
    }

    /// Documents/Users/<userId>/userdata.json — contractors, equipment, disciplines.
    private var userSharedURL: URL {
        userRootURL.appendingPathComponent("userdata.json")
    }

    /// App sandbox Documents/.
    private var sandboxDocumentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Per-account root: Documents/Users/<userId>/
    private var userRootURL: URL {
        Self.userRootURL(for: userId, fileManager: fileManager)
    }

    /// Per-project local root: Documents/Users/<userId>/Projects/<projectId>/
    private var projectRootURL: URL {
        Self.projectRootURL(for: userId, projectId: projectId, fileManager: fileManager)
    }

    /// Documents/Users/<userId>/Projects/<projectId>/Drawings/
    private var drawingsDirectoryURL: URL {
        projectRootURL.appendingPathComponent("Drawings", isDirectory: true)
    }

    /// Documents/Users/<userId>/Projects/<projectId>/IssuePhotos/
    private var issuePhotosDirectoryURL: URL {
        projectRootURL.appendingPathComponent("IssuePhotos", isDirectory: true)
    }

    /// Preview / tests helper — uses fixed isolated ids.
    convenience init() {
        self.init(
            userId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            projectName: "Preview Project"
        )
    }

    /// Opens (or creates) the local workspace for a cloud project.
    /// Does not import legacy account or Documents-root data into this project.
    init(
        userId: UUID,
        projectId: UUID,
        projectName: String,
        createdDate: Date = Date()
    ) {
        self.userId = userId
        self.projectId = projectId

        let fm = FileManager.default
        let userRoot = Self.userRootURL(for: userId, fileManager: fm)
        let projectRoot = Self.projectRootURL(for: userId, projectId: projectId, fileManager: fm)
        try? fm.createDirectory(at: userRoot, withIntermediateDirectories: true)
        for name in ["Drawings", "IssuePhotos"] {
            let dir = projectRoot.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        Self.seedUserSharedFromLegacyAccountIfNeeded(userId: userId, fileManager: fm)

        let projectURL = projectRoot.appendingPathComponent("appdata.json")
        let defaultProject = Project(id: projectId, name: projectName, createdDate: createdDate)
        var projectLocal = ProjectLocalData(project: defaultProject)
        var shared = UserSharedData()
        var loadError: String?
        var untrusted = false
        var needsRewrite = false

        switch Self.loadProjectResult(from: projectURL) {
        case .missing:
            break
        case .loaded(let loaded):
            let (migrated, didChange) = Self.migrateProject(loaded, expectedProjectId: projectId)
            projectLocal = migrated
            needsRewrite = didChange
        case .corrupt:
            _ = Self.preserveCorruptStore(at: projectURL, documentsURL: projectRoot)
            loadError = "Local data could not be loaded"
            untrusted = true
        }

        // Keep the cloud project id/name as the workspace identity.
        if projectLocal.project.id != projectId {
            projectLocal.project.id = projectId
            needsRewrite = true
        }
        if projectLocal.project.name != projectName {
            projectLocal.project.name = projectName
            needsRewrite = true
        }

        switch Self.loadUserSharedResult(from: userRoot.appendingPathComponent("userdata.json")) {
        case .missing:
            break
        case .loaded(let loaded):
            shared = loaded
        case .corrupt:
            if loadError == nil {
                loadError = "Local data could not be loaded"
            }
        }

        // Project + user-global content: SQLite is authoritative after (or instead of) JSON import.
        // Never replace migrated SQLite rows with stale JSON snapshots.
        var sqliteFolders = projectLocal.drawingFolders
        var sqliteDrawings = projectLocal.drawings
        var sqliteIssues = projectLocal.issues
        var sqliteAreas = projectLocal.areas
        var sqliteContractors = shared.contractors
        var sqliteEquipment = shared.equipment
        var sqliteDisciplines = shared.disciplines
        var openedDatabase: AppDatabase?
        var useSQLiteDrawings = false
        var useSQLiteIssuesAreas = false
        var useSQLiteUserShared = false
        do {
            let db = try LocalPersistenceBootstrap.prepareSynchronously(userId: userId)
            try db.ensureProject(projectLocal.project)
            sqliteFolders = try db.fetchDrawingFolders(projectId: projectId)
            sqliteDrawings = try db.fetchDrawings(projectId: projectId)
            sqliteAreas = try db.fetchAreas(projectId: projectId)
            sqliteIssues = try db.fetchIssues(projectId: projectId)
            sqliteContractors = try db.fetchContractors()
            sqliteDisciplines = try db.fetchDisciplines()
            sqliteEquipment = try db.fetchEquipment()
            openedDatabase = db
            useSQLiteDrawings = true
            useSQLiteIssuesAreas = true
            useSQLiteUserShared = true
        } catch {
            print("[AppStore] SQLite project store unavailable: \(error)")
            if loadError == nil {
                loadError = "Local data could not be loaded"
            }
        }

        var loadedData = AppData(
            project: projectLocal.project,
            drawingFolders: sqliteFolders,
            drawings: sqliteDrawings,
            issues: sqliteIssues,
            areas: sqliteAreas,
            equipment: sqliteEquipment,
            contractors: sqliteContractors,
            disciplines: sqliteDisciplines,
            schemaVersion: max(projectLocal.schemaVersion, shared.schemaVersion)
        )
        let (normalized, didNormalize) = Self.normalizedIssueNumbers(loadedData)
        loadedData = normalized
        needsRewrite = needsRewrite || didNormalize

        self.data = loadedData
        self.storageError = loadError
        self.storeFileUntrusted = untrusted
        self.database = openedDatabase
        self.drawingsUseSQLite = useSQLiteDrawings
        self.issuesAreasUseSQLite = useSQLiteIssuesAreas
        self.userSharedUseSQLite = useSQLiteUserShared
        if useSQLiteDrawings && useSQLiteIssuesAreas && useSQLiteUserShared {
            // Exactly what SQLite holds now (before issue-number normalization), so the
            // first save writes only the normalized rows.
            self.sqliteBaseline = SQLiteWorkspaceBaseline(
                projectName: projectLocal.project.name,
                folders: sqliteFolders,
                drawings: sqliteDrawings,
                areas: sqliteAreas,
                issues: sqliteIssues,
                contractors: sqliteContractors,
                disciplines: sqliteDisciplines
            )
        }

        if needsRewrite {
            // Write back schema / identity fixes so the next launch is clean.
            self.persist(clearingLoadError: false)
        }
    }

    /// Updates the displayed project name when the cloud row changes (local storage only).
    func applyCloudProjectName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, data.project.name != trimmed else { return }
        data.project.name = trimmed
        persist()
    }

    /// Reloads drawing folders from SQLite into memory (after a remote pull). Does not enqueue outbox ops.
    func reloadDrawingFoldersFromSQLite() {
        guard drawingsUseSQLite, let database else { return }
        do {
            let folders = try database.fetchDrawingFolders(projectId: projectId)
            var next = data
            next.drawingFolders = folders
            data = next
            sqliteBaseline?.folders = SQLiteWorkspaceBaseline.index(folders)
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Reloads drawings + folders from SQLite after remote pull. Does not enqueue outbox ops.
    /// Does not create PDF files; drawings without a local PDF remain unavailable until download.
    func reloadDrawingsAndFoldersFromSQLite() {
        guard drawingsUseSQLite, let database else { return }
        do {
            let folders = try database.fetchDrawingFolders(projectId: projectId)
            let drawings = try database.fetchDrawings(projectId: projectId)
            var next = data
            next.drawingFolders = folders
            next.drawings = drawings
            data = next
            sqliteBaseline?.folders = SQLiteWorkspaceBaseline.index(folders)
            sqliteBaseline?.drawings = SQLiteWorkspaceBaseline.index(drawings)
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Schedules coordinated sync (push pending, then folder + drawing metadata pull).
    /// Also reconciles drawing metadata outbox for drawings whose PDF upload already completed.
    func scheduleDrawingFolderSync() {
        guard drawingsUseSQLite else { return }
        if let database {
            try? database.reconcileDrawingMetadataOutbox(projectId: projectId)
        }
        DrawingFolderSyncCoordinator.shared.schedule(userId: userId, projectId: projectId) { [weak self] in
            self?.reloadDrawingsAndFoldersFromSQLite()
        }
    }

    private static func userRootURL(for userId: UUID, fileManager: FileManager) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent(userId.uuidString, isDirectory: true)
    }

    private static func projectRootURL(for userId: UUID, projectId: UUID, fileManager: FileManager) -> URL {
        userRootURL(for: userId, fileManager: fileManager)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
    }

    /// One-time seed of user-global dictionaries from the pre-project account file.
    /// Never copies drawings, issues, or photos into a cloud project workspace.
    private static func seedUserSharedFromLegacyAccountIfNeeded(userId: UUID, fileManager: FileManager) {
        let userRoot = userRootURL(for: userId, fileManager: fileManager)
        let sharedURL = userRoot.appendingPathComponent("userdata.json")
        guard !fileManager.fileExists(atPath: sharedURL.path) else { return }

        let legacyAccountStore = userRoot.appendingPathComponent("appdata.json")
        guard case .loaded(let legacy) = loadAppDataResult(from: legacyAccountStore) else { return }

        let shared = UserSharedData(
            contractors: legacy.contractors,
            equipment: legacy.equipment,
            disciplines: legacy.disciplines
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(shared) else { return }
        try? encoded.write(to: sharedURL, options: [.atomic])
    }

    /// Dismisses the in-app storage error banner (does not fix the underlying problem).
    func dismissStorageError() {
        storageError = nil
    }

    // MARK: - Migration

    /// Applies schema migrations on project-local data. Returns whether rewrite is needed.
    private static func migrateProject(
        _ data: ProjectLocalData,
        expectedProjectId: UUID
    ) -> (ProjectLocalData, Bool) {
        var copy = data
        var changed = false

        if copy.schemaVersion < 1 {
            copy.schemaVersion = 1
            changed = true
        }
        if copy.schemaVersion > AppDataSchema.current {
            // Unknown future schema: keep as decoded; do not rewrite.
        } else if copy.schemaVersion != AppDataSchema.current {
            copy.schemaVersion = AppDataSchema.current
            changed = true
        }

        // Folders and drawings must stay bound to this cloud project id.
        for index in copy.drawingFolders.indices where copy.drawingFolders[index].projectId != expectedProjectId {
            copy.drawingFolders[index].projectId = expectedProjectId
            changed = true
        }
        for index in copy.drawings.indices where copy.drawings[index].projectId != expectedProjectId {
            copy.drawings[index].projectId = expectedProjectId
            changed = true
        }
        for index in copy.areas.indices where copy.areas[index].projectId != expectedProjectId {
            copy.areas[index].projectId = expectedProjectId
            changed = true
        }

        let folderIds = Set(copy.drawingFolders.map(\.id))
        // Drop broken parent links (treat as root) and clear orphan drawing folder refs.
        for index in copy.drawingFolders.indices {
            if let parent = copy.drawingFolders[index].parentFolderId,
               parent == copy.drawingFolders[index].id || !folderIds.contains(parent) {
                copy.drawingFolders[index].parentFolderId = nil
                changed = true
            }
        }
        for index in copy.drawings.indices {
            if let folderId = copy.drawings[index].folderId, !folderIds.contains(folderId) {
                copy.drawings[index].folderId = nil
                changed = true
            }
        }

        let drawingIds = Set(copy.drawings.map(\.id))
        let validAreas = copy.areas.filter {
            $0.vertices.count >= 3 && drawingIds.contains($0.drawingId)
        }
        if validAreas.count != copy.areas.count {
            copy.areas = validAreas
            changed = true
        }

        let areaIds = Set(copy.areas.map(\.id))
        for index in copy.issues.indices {
            if let linked = copy.issues[index].areaId, !areaIds.contains(linked) {
                copy.issues[index].areaId = nil
                changed = true
            }
        }

        return (copy, changed)
    }

    /// Assign sequential numbers to any legacy issues that loaded with `number == 0`.
    private static func normalizedIssueNumbers(_ data: AppData) -> (AppData, Bool) {
        var copy = data
        guard copy.issues.contains(where: { $0.number <= 0 }) else { return (copy, false) }

        var next = (copy.issues.map(\.number).filter { $0 > 0 }.max() ?? 0) + 1
        for index in copy.issues.indices.sorted(by: {
            copy.issues[$0].createdDate < copy.issues[$1].createdDate
        }) where copy.issues[index].number <= 0 {
            copy.issues[index].number = next
            next += 1
        }
        return (copy, true)
    }

    // MARK: - File helpers

    /// Absolute URL of a drawing's PDF on disk. Rebuilt from the relative
    /// `fileName` every time because the sandbox path can change between runs.
    func fileURL(for drawing: Drawing) -> URL {
        drawingsDirectoryURL.appendingPathComponent(drawing.fileName)
    }

    // MARK: - Drawing folders

    func folder(id: UUID) -> DrawingFolder? {
        data.drawingFolders.first { $0.id == id }
    }

    /// Child folders of `parentFolderId` (`nil` = project root), sorted for display.
    func folders(in parentFolderId: UUID?) -> [DrawingFolder] {
        data.drawingFolders
            .filter { $0.parentFolderId == parentFolderId }
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Drawings directly inside `folderId` (`nil` = project root).
    func drawings(in folderId: UUID?) -> [Drawing] {
        data.drawings
            .filter { $0.folderId == folderId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isFolderEmpty(_ folderId: UUID) -> Bool {
        !data.drawingFolders.contains(where: { $0.parentFolderId == folderId })
            && !data.drawings.contains(where: { $0.folderId == folderId })
    }

    /// Creates a user-named folder. Returns nil when the name is empty or a sibling clash.
    @discardableResult
    func createFolder(name: String, parentFolderId: UUID?) -> DrawingFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parentFolderId, folder(id: parentFolderId) == nil { return nil }
        guard !siblingFolderNameExists(trimmed, parentFolderId: parentFolderId) else { return nil }

        let nextOrder = (folders(in: parentFolderId).map(\.sortOrder).max() ?? -1) + 1
        let created = DrawingFolder(
            projectId: data.project.id,
            parentFolderId: parentFolderId,
            name: trimmed,
            sortOrder: nextOrder
        )
        if drawingsUseSQLite {
            guard let database else {
                storageError = "Local data could not be saved"
                return nil
            }
            do {
                try database.persistDrawingFolderCreate(created)
            } catch {
                print("[AppStore] Folder create outbox failed: \(error)")
                storageError = "Local data could not be saved"
                return nil
            }
        }
        data.drawingFolders.append(created)
        persist()
        if drawingsUseSQLite {
            SyncOutboxPushService.shared.schedule(userId: userId, projectId: projectId)
        }
        return created
    }

    /// Renames a folder. Returns an error message, or nil on success.
    @discardableResult
    func renameFolder(id: UUID, name: String) -> String? {
        guard let index = data.drawingFolders.firstIndex(where: { $0.id == id }) else {
            return "Folder not found."
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a folder name." }
        let parentId = data.drawingFolders[index].parentFolderId
        if siblingFolderNameExists(trimmed, parentFolderId: parentId, excludingId: id) {
            return "A folder with that name already exists here."
        }
        var renamed = data.drawingFolders[index]
        renamed.name = trimmed
        if drawingsUseSQLite {
            guard let database else {
                storageError = "Local data could not be saved"
                return "Local data could not be saved"
            }
            do {
                try database.persistDrawingFolderRename(renamed)
            } catch {
                print("[AppStore] Folder rename outbox failed: \(error)")
                storageError = "Local data could not be saved"
                return "Local data could not be saved"
            }
        }
        data.drawingFolders[index].name = trimmed
        persist()
        if drawingsUseSQLite {
            SyncOutboxPushService.shared.schedule(userId: userId, projectId: projectId)
        }
        return nil
    }

    /// Deletes a folder only when it has no child folders and no drawings.
    @discardableResult
    func deleteFolder(id: UUID) -> String? {
        guard let existing = folder(id: id) else { return "Folder not found." }
        guard isFolderEmpty(id) else {
            return "Only empty folders can be deleted. Move or delete drawings and subfolders first."
        }
        if drawingsUseSQLite {
            guard let database else {
                storageError = "Local data could not be saved"
                return "Local data could not be saved"
            }
            do {
                try database.persistDrawingFolderDelete(existing)
            } catch {
                print("[AppStore] Folder delete outbox failed: \(error)")
                storageError = "Local data could not be saved"
                return "Local data could not be saved"
            }
        }
        data.drawingFolders.removeAll { $0.id == id }
        persist()
        if drawingsUseSQLite {
            SyncOutboxPushService.shared.schedule(userId: userId, projectId: projectId)
        }
        return nil
    }

    /// Moves a drawing to another folder (`nil` = project root).
    @discardableResult
    func moveDrawing(id: UUID, toFolderId: UUID?) -> String? {
        guard let index = data.drawings.firstIndex(where: { $0.id == id }) else {
            return "Drawing not found."
        }
        if let toFolderId {
            guard let target = folder(id: toFolderId) else { return "Folder not found." }
            guard target.projectId == data.project.id else { return "Folder belongs to another project." }
        }
        guard data.drawings[index].folderId != toFolderId else { return nil }
        data.drawings[index].folderId = toFolderId
        persist()
        return nil
    }

    private func siblingFolderNameExists(
        _ name: String,
        parentFolderId: UUID?,
        excludingId: UUID? = nil
    ) -> Bool {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return data.drawingFolders.contains {
            $0.parentFolderId == parentFolderId
                && $0.id != excludingId
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    // MARK: - Drawings

    /// Import a PDF picked from the Files app: copy it into local storage,
    /// read its page count, and store the metadata record.
    ///
    /// File copy and `PDFDocument` page-count parsing run off the main actor —
    /// large construction PDFs can take seconds to open and would freeze the UI.
    /// - Parameter pickedURL: A security-scoped URL from the document picker.
    /// - Parameter folderId: Destination folder; `nil` places the drawing at project root.
    @discardableResult
    func importDrawing(
        from pickedURL: URL,
        displayName: String? = nil,
        folderId: UUID? = nil
    ) async throws -> Drawing {
        let needsStop = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsStop { pickedURL.stopAccessingSecurityScopedResource() } }
        let fallbackName = pickedURL.deletingPathExtension().lastPathComponent
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name! : fallbackName)
        return try await importPDFFile(
            from: pickedURL,
            displayName: resolvedName.isEmpty ? "Untitled drawing" : resolvedName,
            folderId: folderId
        )
    }

    /// Copies a bundled sample floor plan into local storage.
    @discardableResult
    func importSampleDrawing(_ sample: SampleDrawing, folderId: UUID? = nil) async throws -> Drawing {
        guard let bundleURL = Self.bundleURL(for: sample) else {
            throw ImportError.sampleNotFound
        }
        return try await importPDFFile(from: bundleURL, displayName: sample.defaultName, folderId: folderId)
    }

    enum ImportError: LocalizedError {
        case sampleNotFound
        case invalidFolder

        var errorDescription: String? {
            switch self {
            case .sampleNotFound: return "Sample drawing file not found in the app bundle."
            case .invalidFolder: return "That folder is not available in this project."
            }
        }
    }

    private static func bundleURL(for sample: SampleDrawing) -> URL? {
        for subdirectory in ["Resources/SampleDrawings", "SampleDrawings", nil] {
            if let url = Bundle.main.url(forResource: sample.bundleResourceName,
                                         withExtension: "pdf",
                                         subdirectory: subdirectory) {
                return url
            }
        }
        return Bundle.main.url(forResource: sample.bundleResourceName, withExtension: "pdf")
    }

    private func importPDFFile(
        from sourceURL: URL,
        displayName: String,
        folderId: UUID? = nil
    ) async throws -> Drawing {
        try fileManager.createDirectory(at: drawingsDirectoryURL, withIntermediateDirectories: true)

        let resolvedFolderId: UUID?
        if let folderId {
            guard let folder = folder(id: folderId), folder.projectId == data.project.id else {
                throw ImportError.invalidFolder
            }
            resolvedFolderId = folderId
        } else {
            resolvedFolderId = nil
        }

        let newId = UUID()
        let storedFileName = "\(newId.uuidString).pdf"
        let destinationURL = drawingsDirectoryURL.appendingPathComponent(storedFileName)
        let projectId = data.project.id

        let pageCount = try await Self.copyPDFAndReadPageCount(from: sourceURL, to: destinationURL)

        let drawing = Drawing(
            id: newId,
            projectId: projectId,
            folderId: resolvedFolderId,
            name: displayName,
            fileName: storedFileName,
            pageCount: pageCount
        )

        data.drawings.append(drawing)
        persist()
        enqueueDrawingPDFUploadIfNeeded(drawing, localURL: destinationURL)
        return drawing
    }

    /// Queues a Storage upload for a newly imported PDF only (never bulk-legacy).
    /// Local file is left in place; completion is recorded only after remote confirm.
    private func enqueueDrawingPDFUploadIfNeeded(_ drawing: Drawing, localURL: URL) {
        guard drawingsUseSQLite, let database else { return }
        let bytes = (try? fileManager.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .int64Value
        do {
            _ = try database.enqueueDrawingPDFUpload(
                drawingId: drawing.id,
                projectId: projectId,
                fileName: drawing.fileName,
                bytesTotal: bytes
            )
            DrawingPDFUploadCoordinator.shared.schedule(userId: userId, projectId: projectId)
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Retries incomplete drawing PDF uploads for this workspace (network / restart recovery).
    func scheduleDrawingPDFUploads() {
        guard drawingsUseSQLite else { return }
        DrawingPDFUploadCoordinator.shared.schedule(userId: userId, projectId: projectId)
    }

    /// True when the drawing's PDF bytes exist under the project Drawings directory.
    func isLocalPDFAvailable(for drawing: Drawing) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: drawing).path)
    }

    func isDownloadingPDF(drawingId: UUID) -> Bool {
        pdfDownloadInFlight.contains(drawingId)
    }

    func pdfDownloadError(drawingId: UUID) -> String? {
        pdfDownloadErrors[drawingId]
    }

    /// On-demand download of a remote drawing PDF into the local Drawings folder.
    /// Uses the pending `file_transfers` download row from metadata pull (or a completed upload path).
    func downloadDrawingPDF(_ drawing: Drawing) {
        guard drawingsUseSQLite, let database else {
            storageError = "Local database unavailable for PDF download"
            return
        }
        guard drawing.projectId == projectId else { return }
        if isLocalPDFAvailable(for: drawing) {
            pdfDownloadErrors[drawing.id] = nil
            return
        }
        guard !pdfDownloadInFlight.contains(drawing.id) else { return }

        do {
            if try database.fetchDrawingPDFDownload(drawingId: drawing.id) == nil {
                _ = try database.ensureDrawingPDFDownloadQueued(
                    drawingId: drawing.id,
                    projectId: projectId,
                    fileName: drawing.fileName
                )
            }
            guard try database.fetchDrawingPDFDownload(drawingId: drawing.id) != nil else {
                pdfDownloadErrors[drawing.id] = "Remote PDF path unknown — sync the project first"
                return
            }
        } catch {
            pdfDownloadErrors[drawing.id] = error.localizedDescription
            return
        }

        pdfDownloadInFlight.insert(drawing.id)
        pdfDownloadErrors[drawing.id] = nil
        let drawingId = drawing.id
        Task { @MainActor in
            let ok = await DrawingPDFDownloadCoordinator.shared.downloadNow(
                drawingId: drawingId,
                userId: userId,
                projectId: projectId,
                database: database
            )
            pdfDownloadInFlight.remove(drawingId)
            if ok, isLocalPDFAvailable(for: drawing) {
                pdfDownloadErrors[drawingId] = nil
                // Nudge observers so DrawingDetailView can mount PDFKitView.
                objectWillChange.send()
            } else if !ok {
                let message = (try? database.fetchDrawingPDFDownload(drawingId: drawingId))?.error
                    ?? "PDF download failed"
                pdfDownloadErrors[drawingId] = message
            }
        }
    }

    /// Retries incomplete drawing PDF downloads after reconnect (does not auto-fetch all remotes).
    func scheduleDrawingPDFDownloads() {
        guard drawingsUseSQLite else { return }
        DrawingPDFDownloadCoordinator.shared.schedule(userId: userId, projectId: projectId)
    }

    /// Copies the PDF and reads `pageCount` off the main thread.
    private static func copyPDFAndReadPageCount(from sourceURL: URL, to destinationURL: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = CFAbsoluteTimeGetCurrent()
                do {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destinationURL.path) {
                        try fm.removeItem(at: destinationURL)
                    }
                    try fm.copyItem(at: sourceURL, to: destinationURL)
                    let pageCount = PDFDocument(url: destinationURL)?.pageCount ?? 0
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    print("[AppStore] import copy+pageCount \(String(format: "%.2f", elapsed))s pages=\(pageCount) \(destinationURL.lastPathComponent)")
                    continuation.resume(returning: pageCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Updates name and optional metadata. File, page count and calibrations stay as stored.
    func updateDrawingDetails(id: UUID,
                              name: String,
                              revision: String?,
                              discipline: String?,
                              location: String?,
                              drawingDate: Date?) {
        guard let index = data.drawings.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        data.drawings[index].name = trimmedName
        data.drawings[index].revision = Drawing.nonEmpty(revision)
        data.drawings[index].discipline = Drawing.nonEmpty(discipline)
        data.drawings[index].location = Drawing.nonEmpty(location)
        data.drawings[index].drawingDate = drawingDate
        persist()
    }

    /// Deletes a drawing and its copied PDF.
    ///
    /// Drawings that still have issues are blocked unless `confirmingIssueDeletion`
    /// is true, so issue records and photos are not removed by an accidental swipe.
    /// - Returns: `nil` on success, or a short reason when delete is blocked.
    @discardableResult
    func deleteDrawing(_ drawing: Drawing, confirmingIssueDeletion: Bool = false) -> String? {
        let relatedIssues = data.issues.filter { $0.drawingId == drawing.id }
        if !relatedIssues.isEmpty && !confirmingIssueDeletion {
            let count = relatedIssues.count
            let noun = count == 1 ? "issue" : "issues"
            return "This drawing has \(count) \(noun). Deleting it also deletes those \(noun) and their photos."
        }

        let url = fileURL(for: drawing)
        try? fileManager.removeItem(at: url)
        for photo in relatedIssues.flatMap(\.photos) {
            try? fileManager.removeItem(at: fileURL(for: photo))
        }
        data.drawings.removeAll { $0.id == drawing.id }
        data.issues.removeAll { $0.drawingId == drawing.id }
        data.areas.removeAll { $0.drawingId == drawing.id }
        persist()
        return nil
    }

    /// Save (or replace) the calibration for a page of a drawing.
    func setCalibration(_ calibration: PageCalibration, for drawing: Drawing) {
        guard let index = data.drawings.firstIndex(where: { $0.id == drawing.id }) else { return }
        data.drawings[index].calibrations.removeAll { $0.pageIndex == calibration.pageIndex }
        data.drawings[index].calibrations.append(calibration)
        persist()
    }

    /// Always read the freshest copy of a drawing from the store (records are
    /// value types, so views may be holding a stale snapshot).
    func currentDrawing(_ drawing: Drawing) -> Drawing {
        data.drawings.first { $0.id == drawing.id } ?? drawing
    }

    // MARK: - Issues

    func addIssue(_ issue: Issue) {
        data.issues.append(issue)
        persist()
    }

    func updateIssue(_ issue: Issue) {
        guard let index = data.issues.firstIndex(where: { $0.id == issue.id }) else { return }
        data.issues[index] = issue
        persist()
    }

    /// Updates editable issue fields. Pin coordinates, number and photos stay as stored.
    func updateIssueDetails(id: UUID,
                            title: String,
                            details: String,
                            status: IssueStatus,
                            discipline: String?,
                            contractor: String?,
                            areaId: UUID?) {
        guard let index = data.issues.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        data.issues[index].title = trimmedTitle
        data.issues[index].details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        data.issues[index].status = status
        let trimmedDiscipline = discipline?.trimmingCharacters(in: .whitespacesAndNewlines)
        data.issues[index].discipline = (trimmedDiscipline?.isEmpty == false) ? trimmedDiscipline : nil
        let trimmedContractor = contractor?.trimmingCharacters(in: .whitespacesAndNewlines)
        data.issues[index].contractor = (trimmedContractor?.isEmpty == false) ? trimmedContractor : nil
        // Only accept areas on the same drawing/page; nil clears the assignment.
        if let areaId {
            let issue = data.issues[index]
            let matches = data.areas.contains {
                $0.id == areaId && $0.drawingId == issue.drawingId && $0.pageIndex == issue.pageIndex
            }
            data.issues[index].areaId = matches ? areaId : nil
        } else {
            data.issues[index].areaId = nil
        }
        persist()
    }

    /// Removes an issue, its pin data, and linked photo files on disk.
    func deleteIssue(_ issue: Issue) {
        for photo in issue.photos {
            try? fileManager.removeItem(at: fileURL(for: photo))
        }
        data.issues.removeAll { $0.id == issue.id }
        persist()
    }

    func issue(id: UUID) -> Issue? {
        data.issues.first { $0.id == id }
    }

    func issues(for drawing: Drawing) -> [Issue] {
        data.issues.filter { $0.drawingId == drawing.id }
    }

    /// Next project-wide issue number (1-based, stable after assignment).
    func nextIssueNumber() -> Int {
        (data.issues.map(\.number).max() ?? 0) + 1
    }

    // MARK: - Areas

    func addArea(_ area: Area) {
        guard area.vertices.count >= 3 else { return }
        if issuesAreasUseSQLite {
            guard let database else {
                storageError = "Local data could not be saved"
                return
            }
            do {
                try database.persistAreaCreate(area)
            } catch {
                print("[AppStore] Area create outbox failed: \(error)")
                storageError = "Local data could not be saved"
                return
            }
        }
        data.areas.append(area)
        persist()
        if issuesAreasUseSQLite {
            SyncOutboxPushService.shared.schedule(userId: userId, projectId: projectId)
        }
    }

    func updateArea(_ area: Area) {
        guard area.vertices.count >= 3,
              let index = data.areas.firstIndex(where: { $0.id == area.id }) else { return }
        var updated = area
        updated.updatedDate = Date()
        data.areas[index] = updated
        persist()
    }

    /// Renames an area and optionally updates its color. Geometry stays as stored.
    func updateAreaDetails(id: UUID, name: String, color: String) {
        guard let index = data.areas.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        data.areas[index].name = trimmed
        data.areas[index].color = color
        data.areas[index].updatedDate = Date()
        persist()
    }

    /// Replaces polygon vertices only. Name, color, visibility and issue links stay as stored.
    func updateAreaVertices(id: UUID, vertices: [PDFPoint]) {
        guard vertices.count >= 3,
              let index = data.areas.firstIndex(where: { $0.id == id }) else { return }
        data.areas[index].vertices = vertices
        data.areas[index].updatedDate = Date()
        persist()
    }

    func deleteArea(_ area: Area) {
        data.areas.removeAll { $0.id == area.id }
        for index in data.issues.indices where data.issues[index].areaId == area.id {
            data.issues[index].areaId = nil
        }
        persist()
    }

    func area(id: UUID) -> Area? {
        data.areas.first { $0.id == id }
    }

    func areas(for drawing: Drawing) -> [Area] {
        data.areas.filter { $0.drawingId == drawing.id }
    }

    /// Areas on a specific drawing page, sorted by name (for issue assignment pickers).
    func areas(forDrawingId drawingId: UUID, pageIndex: Int) -> [Area] {
        data.areas
            .filter { $0.drawingId == drawingId && $0.pageIndex == pageIndex }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Contractors dictionary

    @discardableResult
    func addContractor(name: String, notes: String? = nil) -> Contractor? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contractor = Contractor(
            name: trimmed,
            notes: (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil
        )
        data.contractors.append(contractor)
        persist()
        return contractor
    }

    func updateContractor(_ contractor: Contractor) {
        guard let index = data.contractors.firstIndex(where: { $0.id == contractor.id }) else { return }
        let oldName = data.contractors[index].name
        let trimmed = contractor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = contractor
        updated.name = trimmed
        let notes = contractor.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = (notes?.isEmpty == false) ? notes : nil
        data.contractors[index] = updated
        if oldName != trimmed {
            for i in data.issues.indices where data.issues[i].contractor == oldName {
                data.issues[i].contractor = trimmed
            }
        }
        persist()
    }

    /// Deletes a contractor when no issue still references its name.
    /// - Returns: `nil` on success, or a short reason when delete is blocked.
    @discardableResult
    func deleteContractor(_ contractor: Contractor) -> String? {
        let inUse = data.issues.contains { $0.contractor == contractor.name }
        if inUse {
            return "This contractor is used by one or more issues. Remove or change those issues first."
        }
        data.contractors.removeAll { $0.id == contractor.id }
        persist()
        return nil
    }

    // MARK: - Disciplines dictionary

    @discardableResult
    func addDiscipline(name: String) -> Discipline? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let discipline = Discipline(name: trimmed)
        data.disciplines.append(discipline)
        persist()
        return discipline
    }

    func updateDiscipline(_ discipline: Discipline) {
        guard let index = data.disciplines.firstIndex(where: { $0.id == discipline.id }) else { return }
        let oldName = data.disciplines[index].name
        let trimmed = discipline.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = discipline
        updated.name = trimmed
        data.disciplines[index] = updated
        if oldName != trimmed {
            for i in data.issues.indices where data.issues[i].discipline == oldName {
                data.issues[i].discipline = trimmed
            }
        }
        persist()
    }

    /// Deletes a discipline when no issue still references its name.
    /// - Returns: `nil` on success, or a short reason when delete is blocked.
    @discardableResult
    func deleteDiscipline(_ discipline: Discipline) -> String? {
        let inUse = data.issues.contains { $0.discipline == discipline.name }
        if inUse {
            return "This discipline is used by one or more issues. Remove or change those issues first."
        }
        data.disciplines.removeAll { $0.id == discipline.id }
        persist()
        return nil
    }

    // MARK: - Equipment
    // Equipment is managed by `EquipmentStore` (targeted SQLite checkout transactions).
    // `data.equipment` is the launch snapshot only and is never written back from here.

    // MARK: - Issue photos

    /// Absolute URL of an issue photo on disk. Rebuilt from the relative
    /// `fileName` every time because the sandbox path can change between runs.
    func fileURL(for photo: IssuePhoto) -> URL {
        issuePhotosDirectoryURL.appendingPathComponent(photo.fileName)
    }

    /// Loads a photo from disk. Returns `nil` when the file is missing or unreadable.
    func image(for photo: IssuePhoto) -> UIImage? {
        let url = fileURL(for: photo)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// JPEG-encodes `image`, writes it under Documents/IssuePhotos with a UUID
    /// file name, and appends metadata on the issue.
    @discardableResult
    func addPhoto(from image: UIImage, to issueId: UUID) -> IssuePhoto? {
        guard let index = data.issues.firstIndex(where: { $0.id == issueId }) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }

        do {
            try fileManager.createDirectory(at: issuePhotosDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[AppStore] Failed to create IssuePhotos directory: \(error)")
            return nil
        }

        var photoId = UUID()
        var fileName = "\(photoId.uuidString).jpg"
        var destination = issuePhotosDirectoryURL.appendingPathComponent(fileName)
        while fileManager.fileExists(atPath: destination.path) {
            photoId = UUID()
            fileName = "\(photoId.uuidString).jpg"
            destination = issuePhotosDirectoryURL.appendingPathComponent(fileName)
        }

        do {
            try jpeg.write(to: destination, options: [.atomic])
        } catch {
            print("[AppStore] Failed to write photo: \(error)")
            return nil
        }

        let photo = IssuePhoto(id: photoId, fileName: fileName)
        data.issues[index].photos.append(photo)
        persist()
        return photo
    }

    /// Deletes a photo file and removes its metadata from the issue.
    func deletePhoto(_ photo: IssuePhoto, from issueId: UUID) {
        guard let index = data.issues.firstIndex(where: { $0.id == issueId }) else { return }
        try? fileManager.removeItem(at: fileURL(for: photo))
        data.issues[index].photos.removeAll { $0.id == photo.id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        persist(clearingLoadError: true)
    }

    /// Writes SQLite project + user-shared content (when enabled) plus residual JSON.
    /// Migrated entities are never dual-written: SQLite is sole writer; JSON keeps a
    /// frozen recovery snapshot of those arrays from disk.
    private func persist(clearingLoadError: Bool) {
        do {
            try fileManager.createDirectory(at: projectRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: userRootURL, withIntermediateDirectories: true)

            if drawingsUseSQLite || issuesAreasUseSQLite || userSharedUseSQLite {
                guard let database else {
                    throw NSError(
                        domain: "AppStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "SQLite project store is not open"]
                    )
                }
                // Single transaction so drawing UPSERTs never CASCADE-wipe issues/areas.
                if drawingsUseSQLite && issuesAreasUseSQLite, let baseline = sqliteBaseline {
                    // Only what changed since the last successful save (full graph was
                    // O(project size) rows on the main actor for every edit).
                    let delta = baseline.delta(to: data)
                    if !delta.isEmpty || baseline.projectName != data.project.name {
                        try database.persistProjectWorkspaceDelta(project: data.project, delta: delta)
                    }
                } else if drawingsUseSQLite && issuesAreasUseSQLite {
                    try database.persistProjectWorkspace(
                        project: data.project,
                        folders: data.drawingFolders,
                        drawings: data.drawings,
                        areas: data.areas,
                        issues: data.issues
                    )
                } else if drawingsUseSQLite {
                    try database.replaceFoldersAndDrawings(
                        project: data.project,
                        folders: data.drawingFolders,
                        drawings: data.drawings
                    )
                } else if issuesAreasUseSQLite {
                    try database.replaceAreasAndIssues(
                        project: data.project,
                        areas: data.areas,
                        issues: data.issues
                    )
                }

                if userSharedUseSQLite,
                   sqliteBaseline == nil
                    || sqliteBaseline?.contractors != data.contractors
                    || sqliteBaseline?.disciplines != data.disciplines {
                    // Equipment is written only through EquipmentStore's transactional API.
                    try database.persistUserShared(
                        contractors: data.contractors,
                        disciplines: data.disciplines,
                        equipment: nil
                    )
                }
                if sqliteBaseline != nil {
                    sqliteBaseline = SQLiteWorkspaceBaseline(data: data)
                }
            }

            // With every entity array frozen, the JSON files only depend on project identity
            // and schema version; skip the decode → encode → copy → write cycle when unchanged.
            let jsonFullyFrozen = drawingsUseSQLite && issuesAreasUseSQLite && userSharedUseSQLite
            let jsonKey = FrozenJSONKey(project: data.project, schemaVersion: data.schemaVersion)
            if jsonFullyFrozen, !storeFileUntrusted, lastFrozenJSONKey == jsonKey {
                if clearingLoadError {
                    storageError = nil
                } else if storageError == "Local data could not be saved" {
                    storageError = nil
                }
                return
            }

            if !storeFileUntrusted, fileManager.fileExists(atPath: storeURL.path) {
                try? fileManager.removeItem(at: lastGoodURL)
                try? fileManager.copyItem(at: storeURL, to: lastGoodURL)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            // JSON arrays for SQLite-authoritative entities stay frozen for recovery.
            let frozen = Self.frozenProjectEntitySnapshot(from: storeURL)
            let jsonFolders = drawingsUseSQLite ? frozen.folders : data.drawingFolders
            let jsonDrawings = drawingsUseSQLite ? frozen.drawings : data.drawings
            let jsonIssues = issuesAreasUseSQLite ? frozen.issues : data.issues
            let jsonAreas = issuesAreasUseSQLite ? frozen.areas : data.areas

            let frozenShared = Self.frozenUserSharedSnapshot(from: userSharedURL)
            let jsonContractors = userSharedUseSQLite ? frozenShared.contractors : data.contractors
            let jsonEquipment = userSharedUseSQLite ? frozenShared.equipment : data.equipment
            let jsonDisciplines = userSharedUseSQLite ? frozenShared.disciplines : data.disciplines

            let projectLocal = ProjectLocalData(
                project: data.project,
                drawingFolders: jsonFolders,
                drawings: jsonDrawings,
                issues: jsonIssues,
                areas: jsonAreas,
                schemaVersion: data.schemaVersion
            )
            let shared = UserSharedData(
                contractors: jsonContractors,
                equipment: jsonEquipment,
                disciplines: jsonDisciplines,
                schemaVersion: data.schemaVersion
            )

            try encoder.encode(projectLocal).write(to: storeURL, options: [.atomic])
            try encoder.encode(shared).write(to: userSharedURL, options: [.atomic])
            storeFileUntrusted = false
            lastFrozenJSONKey = jsonFullyFrozen ? jsonKey : nil

            if clearingLoadError {
                storageError = nil
            } else if storageError == "Local data could not be saved" {
                storageError = nil
            }
        } catch {
            print("[AppStore] Failed to persist data: \(error)")
            storageError = "Local data could not be saved"
        }
    }

    /// Reads project entity arrays currently on disk for JSON recovery preservation.
    private static func frozenProjectEntitySnapshot(from url: URL) -> (
        folders: [DrawingFolder],
        drawings: [Drawing],
        issues: [Issue],
        areas: [Area]
    ) {
        switch loadProjectResult(from: url) {
        case .loaded(let local):
            return (local.drawingFolders, local.drawings, local.issues, local.areas)
        case .missing, .corrupt:
            return ([], [], [], [])
        }
    }

    /// Reads user-shared arrays currently on disk for JSON recovery preservation.
    private static func frozenUserSharedSnapshot(from url: URL) -> (
        contractors: [Contractor],
        equipment: [EquipmentItem],
        disciplines: [Discipline]
    ) {
        switch loadUserSharedResult(from: url) {
        case .loaded(let shared):
            return (shared.contractors, shared.equipment, shared.disciplines)
        case .missing, .corrupt:
            return ([], [], [])
        }
    }

    private enum ProjectLoadResult {
        case missing
        case loaded(ProjectLocalData)
        case corrupt
    }

    private enum UserSharedLoadResult {
        case missing
        case loaded(UserSharedData)
        case corrupt
    }

    private enum AppDataLoadResult {
        case missing
        case loaded(AppData)
        case corrupt
    }

    private static func loadProjectResult(from url: URL) -> ProjectLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let raw = try? Data(contentsOf: url) else { return .corrupt }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(ProjectLocalData.self, from: raw) {
            return .loaded(decoded)
        }
        // Older combined documents are accepted only for decode robustness; we never
        // pull contractors/equipment from a project file into user-shared storage here.
        if let legacy = try? decoder.decode(AppData.self, from: raw) {
            return .loaded(
                ProjectLocalData(
                    project: legacy.project,
                    drawingFolders: legacy.drawingFolders,
                    drawings: legacy.drawings,
                    issues: legacy.issues,
                    areas: legacy.areas,
                    schemaVersion: legacy.schemaVersion
                )
            )
        }
        print("[AppStore] Failed to decode project appdata.json")
        return .corrupt
    }

    private static func loadUserSharedResult(from url: URL) -> UserSharedLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let raw = try? Data(contentsOf: url) else { return .corrupt }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(UserSharedData.self, from: raw))
        } catch {
            print("[AppStore] Failed to decode userdata.json: \(error)")
            return .corrupt
        }
    }

    private static func loadAppDataResult(from url: URL) -> AppDataLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let raw = try? Data(contentsOf: url) else { return .corrupt }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(AppData.self, from: raw))
        } catch {
            return .corrupt
        }
    }

    /// Copies a corrupt store aside. Does not delete or overwrite the original.
    @discardableResult
    private static func preserveCorruptStore(at url: URL, documentsURL: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = documentsURL
            .appendingPathComponent("appdata-corrupt-\(stamp).json")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            print("[AppStore] Failed to preserve corrupt appdata: \(error)")
            return nil
        }
    }
}

/// Snapshot of what `AppStore` last read from or wrote to SQLite, keyed by id.
/// Internal (not private) so the DEBUG `WorkspaceDeltaPersistenceVerification` can drive it.
struct SQLiteWorkspaceBaseline {
    var projectName: String
    var folders: [UUID: DrawingFolder]
    var drawings: [UUID: Drawing]
    var areas: [UUID: Area]
    var issues: [UUID: Issue]
    var contractors: [Contractor]
    var disciplines: [Discipline]

    init(
        projectName: String,
        folders: [DrawingFolder],
        drawings: [Drawing],
        areas: [Area],
        issues: [Issue],
        contractors: [Contractor],
        disciplines: [Discipline]
    ) {
        self.projectName = projectName
        self.folders = Self.index(folders)
        self.drawings = Self.index(drawings)
        self.areas = Self.index(areas)
        self.issues = Self.index(issues)
        self.contractors = contractors
        self.disciplines = disciplines
    }

    init(data: AppData) {
        self.init(
            projectName: data.project.name,
            folders: data.drawingFolders,
            drawings: data.drawings,
            areas: data.areas,
            issues: data.issues,
            contractors: data.contractors,
            disciplines: data.disciplines
        )
    }

    /// Last value wins for duplicate ids (same as the sequential UPSERTs it replaces).
    static func index<T: Identifiable>(_ items: [T]) -> [UUID: T] where T.ID == UUID {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Rows to upsert (new or changed) and ids to delete (present before, gone now).
    func delta(to data: AppData) -> ProjectWorkspaceDelta {
        var result = ProjectWorkspaceDelta()
        (result.upsertFolders, result.deletedFolderIds) = Self.diff(data.drawingFolders, against: folders)
        (result.upsertDrawings, result.deletedDrawingIds) = Self.diff(data.drawings, against: drawings)
        (result.upsertAreas, result.deletedAreaIds) = Self.diff(data.areas, against: areas)
        (result.upsertIssues, result.deletedIssueIds) = Self.diff(data.issues, against: issues)

        // Parent drawings of changed issues/areas, passed separately so the writer can insert
        // one only when its row is missing (a pull removed it while memory was not reloaded;
        // without the parent the child FK fails, the baseline never advances and every later
        // save fails). They are never used to overwrite an existing row: that would revert
        // newer pulled metadata / folder links from a stale in-memory copy.
        let parentIds = Set(result.upsertIssues.map(\.drawingId)).union(result.upsertAreas.map(\.drawingId))
        if !parentIds.isEmpty {
            let alreadyUpserted = Set(result.upsertDrawings.map(\.id))
            let deleted = Set(result.deletedDrawingIds)
            for drawing in data.drawings
            where parentIds.contains(drawing.id)
                && !alreadyUpserted.contains(drawing.id)
                && !deleted.contains(drawing.id) {
                result.ensureParentDrawings.append(drawing)
            }
        }
        return result
    }

    private static func diff<T: Identifiable & Equatable>(
        _ current: [T],
        against previous: [UUID: T]
    ) -> (changed: [T], removed: [UUID]) where T.ID == UUID {
        var changed: [T] = []
        var seen = Set<UUID>()
        seen.reserveCapacity(current.count)
        for item in current {
            seen.insert(item.id)
            if previous[item.id] != item {
                changed.append(item)
            }
        }
        let removed = previous.keys.filter { !seen.contains($0) }
        return (changed, removed)
    }
}

/// Inputs that still vary in the residual JSON files once all entity arrays are frozen.
private struct FrozenJSONKey: Equatable {
    var project: Project
    var schemaVersion: Int
}
