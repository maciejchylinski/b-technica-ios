// Debug-only demo workspace (fictional data, no Supabase).
#if DEBUG
import Foundation
import GRDB

/// Seeds the DEBUG demo workspace from the bundled `demo-fixture-*` files.
///
/// All records go through the app's own persistence APIs (workspace writer, contacts,
/// photos, schedule, knowledge, equipment), none of which enqueue outbox rows or file
/// transfers. PDF drawings are copied byte-for-byte, photos are converted to JPEG with
/// `PhotoImageProcessing`, documents are stored with `DocumentFileStorage` and left
/// "pending" so the app's own indexer extracts their text.
///
/// Idempotent: the manifest `seedVersion` is stored in `sync_state`; when it matches
/// nothing is written. Otherwise (or with `force`) the demo database rows and the demo
/// user's project files are wiped first, so re-seeding never duplicates records.
/// Refuses to run on any database that does not belong to `DemoMode.userId`.
struct DemoDataSeeder {
    static let markerKey = "demo.seed.version"
    static let manifestResource = "demo-fixture-manifest"

    let database: AppDatabase
    var bundle: Bundle = .main
    var calendar: Calendar = .current
    var now: Date = Date()

    struct Report: Sendable {
        /// False when the stored seed version already matched (nothing written).
        var seeded: Bool
        var seedVersion: String
        var projects: [DemoProjectSummary]
    }

    enum SeedError: LocalizedError {
        case notDemoDatabase
        case manifestMissing
        case manifestMismatch(String)
        case resourceMissing(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .notDemoDatabase: return "Demo data can only be written to the demo workspace database."
            case .manifestMissing: return "demo-fixture-manifest.json is missing from the app bundle."
            case .manifestMismatch(let field): return "Demo manifest does not match this build (\(field))."
            case .resourceMissing(let name): return "Demo fixture file is missing from the app bundle: \(name)"
            case .invalidValue(let value): return "Invalid value in the demo manifest: \(value)"
            }
        }
    }

    // MARK: - Entry point

    func seed(force: Bool = false) throws -> Report {
        guard database.userId == DemoMode.userId else { throw SeedError.notDemoDatabase }
        let manifest = try Self.loadManifest(bundle: bundle)
        guard UUID(uuidString: manifest.demoUserId) == DemoMode.userId else {
            throw SeedError.manifestMismatch("demoUserId")
        }
        let today = calendar.startOfDay(for: now)
        let summaries = try manifest.projects.map { try summary(for: $0, today: today) }
        if !force, try storedSeedVersion() == manifest.seedVersion {
            return Report(seeded: false, seedVersion: manifest.seedVersion, projects: summaries)
        }

        try wipe()
        try seedUserShared(manifest, today: today)
        for project in manifest.projects {
            try seedProject(project, today: today)
        }
        try seedEquipment(manifest, today: today)
        try storeSeedVersion(manifest.seedVersion)
        return Report(seeded: true, seedVersion: manifest.seedVersion, projects: summaries)
    }

    static func loadManifest(bundle: Bundle) throws -> DemoManifest {
        guard let url = bundle.url(forResource: manifestResource, withExtension: "json") else {
            throw SeedError.manifestMissing
        }
        return try JSONDecoder().decode(DemoManifest.self, from: Data(contentsOf: url))
    }

    // MARK: - Marker and wipe (demo database only)

    private func storedSeedVersion() throws -> String? {
        try database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [Self.markerKey])
        }
    }

    private func storeSeedVersion(_ version: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                arguments: [Self.markerKey, version, SQLiteDateCoding.string(from: now)]
            )
        }
    }

    /// Clears every row of the demo database and the demo user's project files. The
    /// database belongs to `DemoMode.userId` (checked in `seed`), so real users are unreachable.
    private func wipe() throws {
        let owner = database.userId.uuidString
        try database.dbQueue.write { db in
            // Knowledge rows first, so their FTS triggers keep the search index consistent.
            try db.execute(sql: "DELETE FROM project_document_pages")
            try db.execute(sql: "DELETE FROM project_documents")
            try db.execute(sql: "DELETE FROM project_notes")
            // Every other project-scoped table cascades from `projects`.
            try db.execute(sql: "DELETE FROM projects")
            for table in ["equipment_items", "contact_people", "contact_companies", "contractors", "disciplines"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE owner_id = ?", arguments: [owner])
            }
            for table in ["sync_outbox", "file_transfers", "sync_state", "json_import_runs"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        let fm = FileManager.default
        let root = database.rootURL
        try? fm.removeItem(at: root.appendingPathComponent("Projects", isDirectory: true))
        for name in ["userdata.json", "userdata-last-good.json", "userdata-pre-sqlite.json"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: - User-global records

    private func seedUserShared(_ manifest: DemoManifest, today: Date) throws {
        let created = date(today, day: -330)
        let contractors = try manifest.contractors.map {
            Contractor(id: try uuid($0.id), name: $0.name, notes: $0.notes, createdDate: created)
        }
        let disciplines = try manifest.disciplines.map {
            Discipline(id: try uuid($0.id), name: $0.name, createdDate: created)
        }
        try database.persistUserShared(contractors: contractors, disciplines: disciplines, equipment: nil)
        for c in manifest.companies {
            try database.persistContactCompany(ContactCompany(
                id: try uuid(c.id), name: c.name, trade: c.trade, taxId: c.taxId, phone: c.phone, email: c.email,
                website: c.website, address: c.address, notes: c.notes, inAddressBook: true,
                createdDate: created, updatedDate: created
            ))
        }
        for p in manifest.people {
            try database.persistContactPerson(ContactPerson(
                id: try uuid(p.id), firstName: p.firstName, lastName: p.lastName, companyId: try optionalUUID(p.companyId),
                jobTitle: p.jobTitle, phone: p.phone, email: p.email, notes: p.notes, inAddressBook: true,
                createdDate: created, updatedDate: created
            ))
        }
    }

    // MARK: - Projects

    private func summary(for project: DemoManifest.Project, today: Date) throws -> DemoProjectSummary {
        DemoProjectSummary(
            id: try uuid(project.id),
            name: project.name,
            description: project.description,
            createdDate: date(today, day: project.createdDayOffset),
            drawingCount: project.drawings.count,
            issueCount: project.issues.count
        )
    }

    private func seedProject(_ p: DemoManifest.Project, today: Date) throws {
        let fm = FileManager.default
        let projectId = try uuid(p.id)
        let created = date(today, day: p.createdDayOffset)
        let project = Project(id: projectId, name: p.name, createdDate: created)
        try database.ensureProject(project)

        let root = database.rootURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
        let drawingsDir = root.appendingPathComponent("Drawings", isDirectory: true)
        let issuePhotosDir = root.appendingPathComponent("IssuePhotos", isDirectory: true)
        try fm.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: issuePhotosDir, withIntermediateDirectories: true)

        // Contacts linked to this project (address-book records were seeded as user-global).
        let links = try p.contactLinks.map { link -> ProjectContactLink in
            let contactId = try uuid(link.contactId)
            let ref: ContactRef = link.kind == "company" ? .company(contactId) : .person(contactId)
            return ProjectContactLink(id: try uuid(link.id), projectId: projectId, contact: ref, role: link.role,
                                      createdDate: created, updatedDate: created)
        }
        try database.persistProjectContactLinks(links)

        // Drawing library: PDFs copied into Drawings/, metadata through the workspace writer.
        let folders = try p.drawingFolders.map {
            DrawingFolder(id: try uuid($0.id), projectId: projectId, parentFolderId: try optionalUUID($0.parentId),
                          name: $0.name, sortOrder: $0.sortOrder, createdDate: created)
        }
        let drawingCreated = date(today, day: p.createdDayOffset + 10)
        var drawings: [Drawing] = []
        for d in p.drawings {
            let id = try uuid(d.id)
            let fileName = "\(id.uuidString).pdf"
            let target = drawingsDir.appendingPathComponent(fileName)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: try resourceURL(d.resource), to: target)
            let calibrations = try d.calibrations.map { c -> PageCalibration in
                guard let unit = LengthUnit(rawValue: c.unit) else { throw SeedError.invalidValue(c.unit) }
                let realMM = unit.toMillimeters(c.enteredValue)
                let distance = hypot(c.bx - c.ax, c.by - c.ay)
                return PageCalibration(
                    id: try uuid(c.id), pageIndex: c.pageIndex,
                    pointA: PDFPoint(x: c.ax, y: c.ay), pointB: PDFPoint(x: c.bx, y: c.by),
                    realDistanceMM: realMM, enteredUnit: unit, enteredValue: c.enteredValue,
                    mmPerPDFUnit: distance > 0 ? realMM / distance : 0, calibratedDate: drawingCreated
                )
            }
            drawings.append(Drawing(
                id: id, projectId: projectId, folderId: try optionalUUID(d.folderId), name: d.name, fileName: fileName,
                pageCount: d.pageCount, createdDate: drawingCreated, revision: d.revision, discipline: d.discipline,
                location: d.location, drawingDate: isoDay(d.drawingDate), calibrations: calibrations
            ))
        }

        let areaCreated = date(today, day: max(p.createdDayOffset + 30, -120))
        let areas = try p.areas.map { a -> Area in
            let vertices = try a.vertices.map { v -> PDFPoint in
                guard v.count == 2 else { throw SeedError.invalidValue("area vertex \(v)") }
                return PDFPoint(x: v[0], y: v[1])
            }
            return Area(id: try uuid(a.id), projectId: projectId, drawingId: try uuid(a.drawingId),
                        pageIndex: a.pageIndex, name: a.name, vertices: vertices, color: a.color,
                        opacity: a.opacity, isVisible: true, createdDate: areaCreated, updatedDate: areaCreated)
        }

        var issues: [Issue] = []
        for i in p.issues {
            guard let status = IssueStatus(rawValue: i.status) else { throw SeedError.invalidValue(i.status) }
            var photos: [IssuePhoto] = []
            for photo in i.photos {
                let photoId = try uuid(photo.id)
                let fileName = "\(photoId.uuidString).jpg"
                try processedImage(photo.resource).fullJPEG
                    .write(to: issuePhotosDir.appendingPathComponent(fileName), options: [.atomic])
                photos.append(IssuePhoto(id: photoId, fileName: fileName,
                                         createdDate: date(today, day: photo.dayOffset, minute: photo.minute)))
            }
            issues.append(Issue(
                id: try uuid(i.id), drawingId: try uuid(i.drawingId), pageIndex: i.pageIndex, pdfX: i.x, pdfY: i.y,
                areaId: try optionalUUID(i.areaId), number: i.number, title: i.title, details: i.details,
                status: status, discipline: i.discipline, contractor: i.contractor,
                createdDate: date(today, day: i.createdDayOffset, minute: i.createdMinute), photos: photos
            ))
        }
        // One transaction for folders, drawings, calibrations, areas, issues and issue photos.
        try database.persistProjectWorkspace(project: project, folders: folders, drawings: drawings,
                                              areas: areas, issues: issues)

        try seedPhotos(p, projectId: projectId, root: root, created: created, today: today)
        if let schedule = p.schedule {
            try seedSchedule(schedule, projectId: projectId, created: created, today: today)
        }
        try seedKnowledge(p, projectId: projectId, root: root, created: created, today: today)
    }

    private func seedPhotos(_ p: DemoManifest.Project, projectId: UUID, root: URL, created: Date, today: Date) throws {
        for a in p.photoAlbums {
            try database.persistPhotoAlbum(PhotoAlbum(id: try uuid(a.id), projectId: projectId, name: a.name,
                                                      sortOrder: a.sortOrder, createdDate: created, updatedDate: created))
        }
        let thumbs = root.appendingPathComponent("Photos/Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        var photos: [ProjectPhoto] = []
        for ph in p.photos {
            let id = try uuid(ph.id)
            let processed = try processedImage(ph.resource)
            let fileName = "Photos/\(id.uuidString).jpg"
            let thumbName = "Photos/Thumbnails/\(id.uuidString).jpg"
            try processed.fullJPEG.write(to: root.appendingPathComponent(fileName), options: [.atomic])
            try processed.thumbnailJPEG.write(to: root.appendingPathComponent(thumbName), options: [.atomic])
            let taken = date(today, day: ph.takenDayOffset, minute: ph.takenMinute)
            let drawingId = try optionalUUID(ph.drawingId)
            photos.append(ProjectPhoto(
                id: id, projectId: projectId, albumId: try optionalUUID(ph.albumId), fileName: fileName,
                thumbnailFileName: thumbName, title: ph.title, description: ph.description, takenDate: taken,
                drawingId: drawingId, pageIndex: drawingId == nil ? nil : ph.pageIndex,
                areaId: try optionalUUID(ph.areaId), issueId: try optionalUUID(ph.issueId),
                pixelWidth: processed.pixelWidth, pixelHeight: processed.pixelHeight,
                byteSize: processed.fullJPEG.count, syncStatus: "local_only", createdDate: taken, updatedDate: taken
            ))
        }
        // Validates album / drawing / area / issue links against this project in one transaction.
        try database.persistProjectPhotos(photos)
    }

    private func seedSchedule(_ s: DemoManifest.Schedule, projectId: UUID, created: Date, today: Date) throws {
        let scheduleId = try uuid(s.id)
        try database.createSchedule(ConstructionSchedule(id: scheduleId, projectId: projectId, name: s.name,
                                                         details: s.details, createdAt: created, updatedAt: created))
        for phase in s.phases {
            try database.savePhase(SchedulePhase(id: try uuid(phase.id), projectId: projectId, scheduleId: scheduleId,
                                                 name: phase.name, colorHex: phase.color, sortOrder: phase.sortOrder,
                                                 createdAt: created, updatedAt: created))
        }
        let base = CalendarDay(today, calendar: calendar)
        for t in s.tasks {
            guard let kind = ScheduleTaskKind(rawValue: t.kind), let status = ScheduleTaskStatus(rawValue: t.status) else {
                throw SeedError.invalidValue("\(t.kind)/\(t.status)")
            }
            // `saveTask` applies the app's schedule rules (ScheduleRules.normalized).
            try database.saveTask(ScheduleTask(
                id: try uuid(t.id), projectId: projectId, scheduleId: scheduleId, phaseId: try optionalUUID(t.phaseId),
                kind: kind, title: t.title, details: t.details,
                startDay: base.adding(days: t.startOffset), finishDay: base.adding(days: t.finishOffset),
                progress: t.progress, status: status, responsibleName: t.responsibleName,
                responsibleContactId: try optionalUUID(t.responsibleLinkId), notes: t.notes, sortOrder: t.sortOrder,
                createdAt: created, updatedAt: created
            ))
        }
        for dep in s.dependencies {
            // Cycle and duplicate checks run inside `addDependency`.
            try database.addDependency(ScheduleDependency(
                id: try uuid(dep.id), projectId: projectId, scheduleId: scheduleId,
                predecessorId: try uuid(dep.predecessorId), successorId: try uuid(dep.successorId),
                type: .finishToStart, createdAt: created, updatedAt: created
            ))
        }
    }

    private func seedKnowledge(_ p: DemoManifest.Project, projectId: UUID, root: URL, created: Date, today: Date) throws {
        for folder in p.documentFolders {
            try database.insertDocumentFolder(ProjectDocumentFolder(
                id: try uuid(folder.id), projectId: projectId, parentFolderId: try optionalUUID(folder.parentId),
                name: folder.name, sortOrder: folder.sortOrder, createdAt: created, updatedAt: created
            ))
        }
        for doc in p.documents {
            let documentId = try uuid(doc.id)
            // Same storage path as a user import; validated with PDFKit and checksummed.
            let stored = try DocumentFileStorage.storePDF(from: try resourceURL(doc.resource), documentId: documentId,
                                                          projectRootURL: root)
            let uploaded = date(today, day: doc.uploadedDayOffset, minute: 10 * 60)
            var document = ProjectDocument.imported(
                id: documentId, projectId: projectId, folderId: try optionalUUID(doc.folderId),
                originalFileName: doc.originalFileName, stored: stored,
                category: DocumentCategory(storedValue: doc.category), now: uploaded
            )
            document.name = doc.name
            document.descriptionText = doc.description
            document.revision = doc.revision
            document.revisionDate = isoDay(doc.revisionDate)
            // Stays `pending`: KnowledgeStore's indexer extracts the text on first open.
            try database.insertProjectDocument(document)
        }
        for note in p.notes {
            let at = date(today, day: note.createdDayOffset, minute: 16 * 60)
            try database.upsertProjectNote(ProjectNote(
                id: try uuid(note.id), projectId: projectId, title: note.title, body: note.body,
                category: note.category.flatMap(NoteCategory.init(rawValue:)), createdAt: at, updatedAt: at
            ))
        }
    }

    // MARK: - Equipment (user-global, history through the transactional API)

    private func seedEquipment(_ manifest: DemoManifest, today: Date) throws {
        for e in manifest.equipment {
            let id = try uuid(e.id)
            try database.createEquipment(
                EquipmentItem(id: id, item: e.name, category: e.category, identifier: e.identifier,
                              serialNumber: e.serialNumber, notes: e.notes),
                date: date(today, day: e.createdDayOffset)
            )
            for action in e.actions {
                let when = date(today, day: action.dayOffset, minute: 8 * 60 + 30)
                switch action.kind {
                case "issue":
                    let recipient: EquipmentRecipient
                    switch action.recipientKind {
                    case "person": recipient = .person(try uuid(action.recipientId ?? ""))
                    case "company": recipient = .company(try uuid(action.recipientId ?? ""))
                    default: recipient = .freeText
                    }
                    _ = try database.issueEquipment(AppDatabase.EquipmentIssueRequest(
                        equipmentId: id, projectId: try uuid(action.projectId ?? ""), recipient: recipient,
                        recipientName: action.recipientName, location: action.location, date: when,
                        notes: action.notes
                    ))
                case "return":
                    let condition = EquipmentReturnCondition(rawValue: action.condition ?? "good") ?? .good
                    try database.returnEquipment(id: id, date: when, condition: condition, notes: action.notes)
                default:
                    throw SeedError.invalidValue(action.kind)
                }
            }
        }
    }

    // MARK: - Helpers

    private func resourceURL(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext) else { throw SeedError.resourceMissing(name) }
        return url
    }

    private func processedImage(_ resource: String) throws -> PhotoImageProcessing.Processed {
        let data = try Data(contentsOf: try resourceURL(resource))
        guard let processed = PhotoImageProcessing.process(data) else { throw SeedError.invalidValue(resource) }
        return processed
    }

    private func uuid(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw SeedError.invalidValue(raw) }
        return id
    }

    private func optionalUUID(_ raw: String?) throws -> UUID? {
        guard let raw else { return nil }
        return try uuid(raw)
    }

    /// Seed day + `day` days + `minute` minutes, in the user's calendar.
    private func date(_ today: Date, day: Int, minute: Int = 9 * 60) -> Date {
        let shifted = calendar.date(byAdding: .day, value: day, to: today) ?? today
        return calendar.date(byAdding: .minute, value: minute, to: shifted) ?? shifted
    }

    /// Fixed ISO day (`yyyy-MM-dd`) at noon in the user's time zone.
    private func isoDay(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
#endif
