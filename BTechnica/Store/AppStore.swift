import Foundation
import PDFKit
import SwiftUI
import UIKit

/// Central observable store for the app.
///
/// Responsibilities:
///  - own the in-memory `AppData` and publish changes to SwiftUI,
///  - persist `AppData` to a JSON file in Documents on every mutation,
///  - manage the on-disk PDF files (copy on import, resolve absolute URLs),
///  - manage issue photo files under Documents/IssuePhotos/.
///
/// This is deliberately a plain `ObservableObject` + JSON rather than a heavy
/// persistence framework, matching the "simple, readable" goal of this slice.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData

    private let fileManager = FileManager.default

    /// Documents/appdata.json
    private var storeURL: URL {
        documentsURL.appendingPathComponent("appdata.json")
    }

    /// Documents/ (app sandbox, backed up, user-visible via Files if enabled).
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Documents/Drawings/ — where imported PDFs are copied.
    private var drawingsDirectoryURL: URL {
        documentsURL.appendingPathComponent("Drawings", isDirectory: true)
    }

    /// Documents/IssuePhotos/ — copied/captured issue photos (JPEG files).
    private var issuePhotosDirectoryURL: URL {
        documentsURL.appendingPathComponent("IssuePhotos", isDirectory: true)
    }

    init() {
        // Ensure local file directories exist before anything else.
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["Drawings", "IssuePhotos"] {
            let dir = docs.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Load existing data or seed a default project.
        let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appdata.json")
        if let loaded = AppStore.load(from: url) {
            let (normalized, didMigrate) = AppStore.normalized(loaded)
            self.data = normalized
            if didMigrate {
                // Write back migrated numbers / field names so the next launch is clean.
                // persist() needs self; call after assignment via a local encode.
                Self.write(normalized, to: url)
            }
        } else {
            self.data = AppData(project: Project(name: "Default Project"))
        }
    }

    /// Assign sequential numbers to any legacy issues that loaded with `number == 0`.
    private static func normalized(_ data: AppData) -> (AppData, Bool) {
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

    private static func write(_ data: AppData, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(data).write(to: url, options: [.atomic])
        } catch {
            print("[AppStore] Failed to persist migrated data: \(error)")
        }
    }

    // MARK: - File helpers

    /// Absolute URL of a drawing's PDF on disk. Rebuilt from the relative
    /// `fileName` every time because the sandbox path can change between runs.
    func fileURL(for drawing: Drawing) -> URL {
        drawingsDirectoryURL.appendingPathComponent(drawing.fileName)
    }

    // MARK: - Drawings

    /// Import a PDF picked from the Files app: copy it into local storage,
    /// read its page count, and store the metadata record.
    /// - Parameter pickedURL: A security-scoped URL from the document picker.
    @discardableResult
    func importDrawing(from pickedURL: URL) throws -> Drawing {
        let needsStop = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsStop { pickedURL.stopAccessingSecurityScopedResource() } }

        try fileManager.createDirectory(at: drawingsDirectoryURL, withIntermediateDirectories: true)

        let newId = UUID()
        let storedFileName = "\(newId.uuidString).pdf"
        let destinationURL = drawingsDirectoryURL.appendingPathComponent(storedFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: pickedURL, to: destinationURL)

        let pageCount = PDFDocument(url: destinationURL)?.pageCount ?? 0

        let displayName = pickedURL.deletingPathExtension().lastPathComponent
        let drawing = Drawing(
            id: newId,
            projectId: data.project.id,
            name: displayName.isEmpty ? "Untitled drawing" : displayName,
            fileName: storedFileName,
            pageCount: pageCount
        )

        data.drawings.append(drawing)
        persist()
        return drawing
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
                            contractor: String?) {
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
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(data)
            try encoded.write(to: storeURL, options: [.atomic])
        } catch {
            print("[AppStore] Failed to persist data: \(error)")
        }
    }

    private static func load(from url: URL) -> AppData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppData.self, from: raw)
    }
}
