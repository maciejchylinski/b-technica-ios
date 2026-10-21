import Foundation
import PDFKit
import SwiftUI
import UIKit

/// Central observable store for one local project workspace.
///
/// Responsibilities:
///  - own in-memory `AppData` and publish changes to SwiftUI,
///  - persist project drawings/issues under `Users/<userId>/Projects/<projectId>/`,
///  - persist user-global contractors/equipment/disciplines under `Users/<userId>/userdata.json`,
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

    /// Authenticated account that owns this local workspace.
    let userId: UUID
    /// Cloud project id this local workspace is bound to.
    let projectId: UUID

    private let fileManager = FileManager.default
    /// When true, the on-disk project `appdata.json` is corrupt/untrusted — do not promote it to last-good.
    private var storeFileUntrusted = false

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

        var loadedData = AppData(
            project: projectLocal.project,
            drawingFolders: projectLocal.drawingFolders,
            drawings: projectLocal.drawings,
            issues: projectLocal.issues,
            areas: projectLocal.areas,
            equipment: shared.equipment,
            contractors: shared.contractors,
            disciplines: shared.disciplines,
            schemaVersion: max(projectLocal.schemaVersion, shared.schemaVersion)
        )
        let (normalized, didNormalize) = Self.normalizedIssueNumbers(loadedData)
        loadedData = normalized
        needsRewrite = needsRewrite || didNormalize

        self.data = loadedData
        self.storageError = loadError
        self.storeFileUntrusted = untrusted

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
        data.drawingFolders.append(created)
        persist()
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
        data.drawingFolders[index].name = trimmed
        persist()
        return nil
    }

    /// Deletes a folder only when it has no child folders and no drawings.
    @discardableResult
    func deleteFolder(id: UUID) -> String? {
        guard folder(id: id) != nil else { return "Folder not found." }
        guard isFolderEmpty(id) else {
            return "Only empty folders can be deleted. Move or delete drawings and subfolders first."
        }
        data.drawingFolders.removeAll { $0.id == id }
        persist()
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
        return drawing
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
        data.areas.append(area)
        persist()
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

    func equipment(id: UUID) -> EquipmentItem? {
        data.equipment.first { $0.id == id }
    }

    @discardableResult
    func addEquipment(name: String,
                      category: String? = nil,
                      identifier: String? = nil,
                      notes: String? = nil) -> EquipmentItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let created = EquipmentEvent(type: .created, notes: EquipmentItem.nonEmpty(notes))
        let item = EquipmentItem(
            item: trimmed,
            category: category,
            identifier: identifier,
            notes: notes,
            status: .available,
            history: [created]
        )
        data.equipment.append(item)
        persist()
        return item
    }

    /// Updates name and optional identity fields. Status / issue state stay as stored.
    func updateEquipmentDetails(id: UUID,
                                name: String,
                                category: String?,
                                identifier: String?,
                                notes: String?) {
        guard let index = data.equipment.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = data.equipment[index]
        let previous = updated
        updated.item = trimmed
        updated.category = EquipmentItem.nonEmpty(category)
        updated.identifier = EquipmentItem.nonEmpty(identifier)
        updated.notes = EquipmentItem.nonEmpty(notes)

        let changed = previous.item != updated.item
            || previous.category != updated.category
            || previous.identifier != updated.identifier
            || previous.notes != updated.notes
        if changed {
            updated.history.append(EquipmentEvent(type: .edited))
            data.equipment[index] = updated
            persist()
        }
    }

    /// Hands out an item. `issuedTo` is required free text (person / company).
    @discardableResult
    func issueEquipment(id: UUID,
                        issuedTo: String,
                        location: String? = nil,
                        date: Date = Date(),
                        notes: String? = nil) -> String? {
        guard let index = data.equipment.firstIndex(where: { $0.id == id }) else {
            return "Equipment not found."
        }
        var item = data.equipment[index]
        guard item.canIssue else {
            return "This item cannot be issued while it is \(item.status.label.lowercased())."
        }
        let person = EquipmentItem.nonEmpty(issuedTo)
        guard let person else {
            return "Enter who the equipment is issued to."
        }

        item.status = .issued
        item.issuedTo = person
        item.location = EquipmentItem.nonEmpty(location)
        item.issuedDate = date
        item.returnedDate = nil
        item.history.append(EquipmentEvent(
            date: date,
            type: .issued,
            person: person,
            location: location,
            notes: notes
        ))
        data.equipment[index] = item
        persist()
        return nil
    }

    /// Marks an issued item as returned (status `.returned`).
    @discardableResult
    func returnEquipment(id: UUID,
                         date: Date = Date(),
                         notes: String? = nil) -> String? {
        guard let index = data.equipment.firstIndex(where: { $0.id == id }) else {
            return "Equipment not found."
        }
        var item = data.equipment[index]
        guard item.canReturn else {
            return "Only issued items can be returned."
        }

        let previousHolder = item.issuedTo
        item.status = .returned
        item.returnedDate = date
        item.issuedTo = nil
        item.history.append(EquipmentEvent(
            date: date,
            type: .returned,
            person: previousHolder,
            location: item.location,
            notes: notes
        ))
        data.equipment[index] = item
        persist()
        return nil
    }

    /// Sets Damaged or Lost (and records a history event).
    @discardableResult
    func markEquipment(id: UUID,
                       status: EquipmentStatus,
                       notes: String? = nil) -> String? {
        guard status == .damaged || status == .lost else {
            return "Only damaged or lost can be set this way."
        }
        guard let index = data.equipment.firstIndex(where: { $0.id == id }) else {
            return "Equipment not found."
        }
        var item = data.equipment[index]
        item.status = status
        if status == .damaged || status == .lost {
            // No longer actively issued.
            item.issuedTo = nil
        }
        let eventType: EquipmentEventType = status == .damaged ? .markedDamaged : .markedLost
        item.history.append(EquipmentEvent(
            type: eventType,
            location: item.location,
            notes: notes
        ))
        data.equipment[index] = item
        persist()
        return nil
    }

    /// Marks a returned/damaged/lost item available again without an issue event.
    @discardableResult
    func markEquipmentAvailable(id: UUID, notes: String? = nil) -> String? {
        guard let index = data.equipment.firstIndex(where: { $0.id == id }) else {
            return "Equipment not found."
        }
        var item = data.equipment[index]
        guard item.status != .issued else {
            return "Return the item before marking it available."
        }
        guard item.status != .available else { return nil }
        item.status = .available
        item.issuedTo = nil
        item.history.append(EquipmentEvent(type: .edited, notes: notes ?? "Marked available"))
        data.equipment[index] = item
        persist()
        return nil
    }

    func deleteEquipment(_ item: EquipmentItem) {
        data.equipment.removeAll { $0.id == item.id }
        persist()
    }

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

    /// Writes project-local and user-shared files atomically.
    private func persist(clearingLoadError: Bool) {
        do {
            try fileManager.createDirectory(at: projectRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: userRootURL, withIntermediateDirectories: true)

            if !storeFileUntrusted, fileManager.fileExists(atPath: storeURL.path) {
                try? fileManager.removeItem(at: lastGoodURL)
                try? fileManager.copyItem(at: storeURL, to: lastGoodURL)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let projectLocal = ProjectLocalData(
                project: data.project,
                drawingFolders: data.drawingFolders,
                drawings: data.drawings,
                issues: data.issues,
                areas: data.areas,
                schemaVersion: data.schemaVersion
            )
            let shared = UserSharedData(
                contractors: data.contractors,
                equipment: data.equipment,
                disciplines: data.disciplines,
                schemaVersion: data.schemaVersion
            )

            try encoder.encode(projectLocal).write(to: storeURL, options: [.atomic])
            try encoder.encode(shared).write(to: userSharedURL, options: [.atomic])
            storeFileUntrusted = false

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
