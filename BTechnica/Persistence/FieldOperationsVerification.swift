// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB
import ImageIO
import UIKit

/// Focused checks for Field Operations SQLite relationships (launch arg `-BTVerifyFieldOperations`):
/// legacy equipment migration, checkout lifecycle invariants, contact project isolation,
/// photo links / cascades, and image downsampling. Runs on temporary databases only.
enum FieldOperationsVerification {
    struct Result {
        var passed: Bool
        var message: String
        var checks: [String]
    }

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() -> Result {
        var log: [String] = []
        do {
            try runThrowing(&log)
            return Result(passed: true, message: "All \(log.count) checks passed", checks: log)
        } catch {
            return Result(passed: false, message: "Failed after \(log.count) checks: \(error.localizedDescription)", checks: log)
        }
    }

    private static func check(_ condition: Bool, _ label: String, _ log: inout [String]) throws {
        guard condition else { throw Failure(message: label) }
        log.append(label)
    }

    private static func expectError(_ label: String, _ log: inout [String], _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            log.append(label)
            return
        }
        throw Failure(message: "\(label) (no error thrown)")
    }

    private static func runThrowing(_ log: inout [String]) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bt-field-ops-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let userId = UUID()

        // MARK: Legacy equipment → checkout migration

        let scratch = try AppDatabase.open(userId: userId, at: root.appendingPathComponent("scratch.sqlite"), rootURL: root)
        var config = Configuration()
        config.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys = ON") }
        let legacyURL = root.appendingPathComponent("legacy.sqlite")
        let legacyQueue = try DatabaseQueue(path: legacyURL.path, configuration: config)
        try scratch.migrator.migrate(legacyQueue, upTo: "v1_foundation")
        let issuedItem = UUID().uuidString
        let returnedItem = UUID().uuidString
        let issuedEvent = UUID().uuidString
        try legacyQueue.write { db in
            let t = SQLiteDateCoding.string(from: Date(timeIntervalSince1970: 1_700_000_000))
            try db.execute(sql: """
                INSERT INTO equipment_items (id, owner_id, item, issued_to, location, issued_at, status)
                VALUES (?, ?, 'Laser level', 'Jan Nowak', 'Level 2', ?, 'issued'),
                       (?, ?, 'Drill', NULL, NULL, NULL, 'returned')
                """, arguments: [issuedItem, userId.uuidString, t, returnedItem, userId.uuidString])
            try db.execute(sql: """
                INSERT INTO equipment_events (id, equipment_id, event_at, event_type, person)
                VALUES (?, ?, ?, 'issued', 'Jan Nowak'), (?, ?, ?, 'returned', 'Ola')
                """, arguments: [issuedEvent, issuedItem, t, UUID().uuidString, returnedItem, t])
        }
        try scratch.migrator.migrate(legacyQueue)
        try legacyQueue.read { db in
            let status = try String.fetchOne(db, sql: "SELECT status FROM equipment_items WHERE id = ?", arguments: [returnedItem])
            try check(status == "available", "legacy 'returned' normalized to 'available'", &log)
            let active = try Row.fetchAll(db, sql: "SELECT * FROM equipment_checkouts WHERE equipment_id = ? AND returned_at IS NULL", arguments: [issuedItem])
            try check(active.count == 1 && (active.first?["recipient_name"] as String?) == "Jan Nowak",
                      "legacy issued item gets exactly one open checkout with holder snapshot", &log)
            let linked = try String.fetchOne(db, sql: "SELECT checkout_id FROM equipment_events WHERE id = ?", arguments: [issuedEvent])
            try check(linked == (active.first?["id"] as String?), "legacy issue event linked to backfilled checkout", &log)
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM equipment_events") ?? 0
            try check(events == 2, "legacy events preserved", &log)
        }
        try legacyQueue.write { try AppDatabase.normalizeEquipmentState($0) }
        let afterRerun = try legacyQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM equipment_checkouts") ?? 0 }
        try check(afterRerun == 1, "normalization is idempotent", &log)

        // MARK: Fixture

        let db = try AppDatabase.open(userId: userId, at: root.appendingPathComponent("main.sqlite"), rootURL: root)
        let p1 = Project(id: UUID(), name: "Site A", createdDate: Date())
        let p2 = Project(id: UUID(), name: "Site B", createdDate: Date())
        try db.ensureProject(p1)
        try db.ensureProject(p2)

        let acme = ContactCompany(name: "Acme Electrical")
        let anna = ContactPerson(firstName: "Anna", lastName: "Kowalska", companyId: acme.id, inAddressBook: false)
        let bob = ContactPerson(firstName: "Bob", lastName: "Builder")
        try db.persistContactCompany(acme, link: ProjectContactLink(projectId: p1.id, contact: .company(acme.id), role: "MEP"))
        try db.persistContactPerson(anna, link: ProjectContactLink(projectId: p1.id, contact: .person(anna.id), role: "Foreman"))
        try db.persistContactPerson(bob, link: ProjectContactLink(projectId: p2.id, contact: .person(bob.id)))

        // MARK: Contacts isolation

        let p1Links = try db.fetchProjectContactLinks(projectId: p1.id)
        let p2Links = try db.fetchProjectContactLinks(projectId: p2.id)
        try check(p1Links.count == 2 && !p1Links.contains { $0.contact == .person(bob.id) },
                  "project A contacts exclude project B people", &log)
        try check(p2Links.map(\.contact) == [.person(bob.id)], "project B contacts exclude project A contacts", &log)
        try expectError("project_contacts requires exactly one of company / person", &log) {
            try db.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO project_contacts (id, project_id, company_id, person_id, created_at, updated_at)
                    VALUES (?, ?, NULL, NULL, 'x', 'x')
                    """, arguments: [UUID().uuidString, p1.id.uuidString])
            }
        }

        // MARK: Checkout lifecycle

        let drill = EquipmentItem(item: "Hammer drill", category: "Power tool", identifier: "BT-014", serialNumber: "SN-1")
        try db.createEquipment(drill)
        let t0 = Date()
        func issue(_ recipient: EquipmentRecipient, project: UUID, at date: Date, handOver: Bool = false, name: String? = nil) throws {
            try db.issueEquipment(.init(equipmentId: drill.id, projectId: project, recipient: recipient,
                                        recipientName: name, location: "Level 1", date: date, notes: nil, handOver: handOver))
        }
        func state() throws -> (status: String, active: [EquipmentCheckout], all: [EquipmentCheckout]) {
            let status = try db.dbQueue.read {
                try String.fetchOne($0, sql: "SELECT status FROM equipment_items WHERE id = ?", arguments: [drill.id.uuidString])
            } ?? ""
            let all = try db.fetchEquipmentCheckouts().filter { $0.equipmentId == drill.id }
            return (status, all.filter(\.isActive), all)
        }

        try expectError("cannot issue to a person outside the project's contacts", &log) {
            try issue(.person(bob.id), project: p1.id, at: t0)
        }
        try issue(.person(anna.id), project: p1.id, at: t0)
        var s = try state()
        try check(s.status == "issued" && s.active.count == 1 && s.active[0].projectId == p1.id
                  && s.active[0].recipientName == "Anna Kowalska", "issue opens one checkout in the project", &log)
        try expectError("second issue without hand-over is refused", &log) {
            try issue(.company(acme.id), project: p1.id, at: t0.addingTimeInterval(60))
        }
        try expectError("unique index rejects a second open checkout", &log) {
            try db.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO equipment_checkouts (id, equipment_id, recipient_kind, recipient_name, issued_at, created_at, updated_at)
                    VALUES (?, ?, 'text', 'Ghost', 'x', 'x', 'x')
                    """, arguments: [UUID().uuidString, drill.id.uuidString])
            }
        }
        try expectError("return dated before issue is refused", &log) {
            try db.returnEquipment(id: drill.id, date: t0.addingTimeInterval(-3600), condition: .good, notes: nil)
        }

        try issue(.person(bob.id), project: p2.id, at: t0.addingTimeInterval(120), handOver: true)
        s = try state()
        let itemCount = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM equipment_items") ?? 0 }
        try check(itemCount == 1 && s.active.count == 1 && s.active[0].projectId == p2.id
                  && s.all.contains { $0.outcome == .handedOver },
                  "hand-over moves item to project B without duplicating it", &log)

        try db.returnEquipment(id: drill.id, date: t0.addingTimeInterval(180), condition: .damaged, notes: "Chuck broken")
        s = try state()
        try check(s.status == "damaged" && s.active.isEmpty, "damaged return closes checkout and marks damaged", &log)
        try expectError("damaged item cannot be issued", &log) {
            try issue(.freeText, project: p1.id, at: t0.addingTimeInterval(200), name: "Visitor")
        }
        try db.restoreEquipment(id: drill.id, notes: "Repaired")
        try check(try state().status == "available", "back in service makes item available", &log)

        try issue(.freeText, project: p1.id, at: t0.addingTimeInterval(240), name: "Agency worker")
        try db.markEquipment(id: drill.id, status: .lost, notes: nil)
        s = try state()
        try check(s.status == "lost" && s.active.isEmpty && s.all.contains { $0.outcome == .lost && $0.recipientName == "Agency worker" },
                  "marking lost closes checkout and keeps the holder", &log)
        try db.restoreEquipment(id: drill.id, notes: nil)

        try issue(.person(anna.id), project: p1.id, at: Date())
        try check(try db.fetchHeldEquipment(by: .person(anna.id)).count == 1, "held equipment lookup by contact", &log)
        try db.removeProjectContact(.person(anna.id), projectId: p1.id)
        s = try state()
        try check(s.active.count == 1 && s.active[0].recipient == .freeText && s.active[0].recipientName == "Anna Kowalska",
                  "deleting holder contact keeps checkout with name snapshot", &log)

        try db.persistUserShared(contractors: [], disciplines: [], equipment: nil)
        let survived = try db.fetchEquipment()
        try check(survived.count == 1 && survived[0].serialNumber == "SN-1", "dictionary save leaves equipment untouched", &log)
        let events = survived[0].history
        try check(events.filter { $0.checkoutId != nil }.count >= 8 && events.contains { $0.type == .handedOver },
                  "history events reference their checkouts", &log)

        let contradictions = try db.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM equipment_items i
                WHERE (i.status = 'issued') <> EXISTS(
                  SELECT 1 FROM equipment_checkouts c WHERE c.equipment_id = i.id AND c.returned_at IS NULL)
                """) ?? -1
        }
        try check(contradictions == 0, "status and open checkout always agree", &log)

        // MARK: Photos

        let drawingId = UUID()
        let areaId = UUID()
        let issueId = UUID()
        try db.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, project_id, name, file_name, page_count, created_at)
                VALUES (?, ?, 'Ground floor', 'x.pdf', 2, 'x')
                """, arguments: [drawingId.uuidString, p1.id.uuidString])
            try db.execute(sql: """
                INSERT INTO areas (id, project_id, drawing_id, page_index, name, vertices_json, color, opacity, created_at, updated_at)
                VALUES (?, ?, ?, 0, 'Zone A', '[]', '#000000', 0.3, 'x', 'x')
                """, arguments: [areaId.uuidString, p1.id.uuidString, drawingId.uuidString])
            try db.execute(sql: """
                INSERT INTO issues (id, project_id, drawing_id, page_index, pdf_x, pdf_y, number, title, status, created_at)
                VALUES (?, ?, ?, 0, 1, 1, 1, 'Crack', 'open', 'x')
                """, arguments: [issueId.uuidString, p1.id.uuidString, drawingId.uuidString])
        }
        let album = PhotoAlbum(id: UUID(), projectId: p1.id, name: "Foundations", sortOrder: 0, createdDate: Date(), updatedDate: Date())
        try db.persistPhotoAlbum(album)
        try expectError("album names are unique per project (case-insensitive)", &log) {
            try db.persistPhotoAlbum(PhotoAlbum(id: UUID(), projectId: p1.id, name: "foundations", sortOrder: 1,
                                                createdDate: Date(), updatedDate: Date()))
        }
        func photo(project: UUID, issue: UUID? = nil, area: UUID? = nil, drawing: UUID? = nil, album: UUID? = nil) -> ProjectPhoto {
            let id = UUID()
            return ProjectPhoto(id: id, projectId: project, albumId: album, fileName: "Photos/\(id).jpg",
                                thumbnailFileName: "Photos/Thumbnails/\(id).jpg", title: "Pour", description: "Slab",
                                takenDate: Date(), drawingId: drawing, pageIndex: drawing == nil ? nil : 0, areaId: area,
                                issueId: issue, pixelWidth: 10, pixelHeight: 10, byteSize: 100,
                                syncStatus: "local_only", createdDate: Date(), updatedDate: Date())
        }
        let linked = photo(project: p1.id, issue: issueId, area: areaId, drawing: drawingId, album: album.id)
        try db.persistProjectPhotos([linked, photo(project: p1.id)])
        try check(try db.fetchProjectPhotos(projectId: p1.id).count == 2, "photos stored for project A", &log)
        try check(try db.fetchProjectPhotos(projectId: p2.id).isEmpty, "project B gallery does not see project A photos", &log)
        try check(try db.fetchProjectPhotos(issueId: issueId).map(\.id) == [linked.id], "issue sees linked documentation photo", &log)
        try expectError("photo in project B cannot link a project A issue", &log) {
            try db.persistProjectPhotos([photo(project: p2.id, issue: issueId)])
        }
        try expectError("photo cannot use an album of another project", &log) {
            try db.persistProjectPhotos([photo(project: p2.id, album: album.id)])
        }

        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM issues WHERE id = ?", arguments: [issueId.uuidString]) }
        try db.deletePhotoAlbum(id: album.id, projectId: p1.id)
        let reloaded = try db.fetchProjectPhotos(projectId: p1.id).first { $0.id == linked.id }
        try check(reloaded?.issueId == nil && reloaded?.albumId == nil && reloaded?.areaId == areaId,
                  "deleting issue / album unlinks photo but keeps it", &log)
        let files = try db.deleteProjectPhotos(ids: [linked.id], projectId: p1.id)
        try check(files == [linked.fileName, linked.thumbnailFileName!], "photo delete returns its files for removal", &log)
        try check(try db.deleteProjectPhotos(ids: [linked.id], projectId: p2.id).isEmpty, "delete is project-scoped", &log)

        // MARK: Image processing

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 5000, height: 2500), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let large = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 5000, height: 2500))
        }
        guard let jpeg = large.jpegData(compressionQuality: 0.8),
              let processed = PhotoImageProcessing.process(jpeg) else {
            throw Failure(message: "image processing returned nil")
        }
        try check(max(processed.pixelWidth, processed.pixelHeight) <= PhotoImageProcessing.maxStoredPixelSize,
                  "stored image capped at \(PhotoImageProcessing.maxStoredPixelSize)px", &log)
        let thumbSource = CGImageSourceCreateWithData(processed.thumbnailJPEG as CFData, nil)
        let thumbProps = thumbSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let thumbWidth = thumbProps?[kCGImagePropertyPixelWidth] as? Int ?? .max
        try check(thumbWidth <= PhotoImageProcessing.thumbnailPixelSize, "thumbnail capped at \(PhotoImageProcessing.thumbnailPixelSize)px", &log)
        try check(PhotoImageProcessing.process(Data("not an image".utf8)) == nil, "damaged image data is rejected", &log)
        try check(PhotoImageProcessing.downsampledImage(at: root.appendingPathComponent("missing.jpg"), maxPixelSize: 100) == nil,
                  "missing image file loads as nil", &log)
    }
}
#endif
