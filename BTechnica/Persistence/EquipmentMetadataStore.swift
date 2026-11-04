import Foundation
import GRDB

/// Targeted, transactional equipment writes. Every state change validates the current
/// SQLite state inside the write transaction, then updates the item, its checkout and its
/// history together, so `equipment_items.status` never disagrees with the open checkout.
extension AppDatabase {
    struct EquipmentIssueRequest {
        var equipmentId: UUID
        var projectId: UUID
        var recipient: EquipmentRecipient
        /// Required for `.freeText`; ignored for contacts (name is read from the contact).
        var recipientName: String?
        var location: String?
        var date: Date
        var notes: String?
        /// When true an item that is already issued is handed over (old checkout closed).
        var handOver: Bool = false
    }

    struct HeldEquipment: Identifiable, Equatable {
        var checkout: EquipmentCheckout
        var itemName: String
        var id: UUID { checkout.id }
    }

    // MARK: - Reads

    func fetchEquipmentCheckouts() throws -> [EquipmentCheckout] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT c.* FROM equipment_checkouts c
                JOIN equipment_items i ON i.id = c.equipment_id
                WHERE i.owner_id = ?
                ORDER BY c.issued_at DESC
                """,
                arguments: [userId.uuidString]
            )
            return try rows.map(Self.checkout(from:))
        }
    }

    /// Open checkouts held by a contact (any project), with the item name.
    func fetchHeldEquipment(by contact: ContactRef) throws -> [HeldEquipment] {
        let (column, id): (String, UUID) = {
            switch contact {
            case .person(let id): return ("person_id", id)
            case .company(let id): return ("company_id", id)
            }
        }()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT c.*, i.item AS item_name FROM equipment_checkouts c
                JOIN equipment_items i ON i.id = c.equipment_id
                WHERE i.owner_id = ? AND c.returned_at IS NULL AND c.\(column) = ?
                ORDER BY i.item COLLATE NOCASE
                """,
                arguments: [userId.uuidString, id.uuidString]
            )
            return try rows.map { HeldEquipment(checkout: try Self.checkout(from: $0), itemName: $0["item_name"]) }
        }
    }

    func fetchLocalProjectNames() throws -> [UUID: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM projects")
            var names: [UUID: String] = [:]
            for row in rows {
                if let id = UUID(uuidString: row["id"]) { names[id] = row["name"] }
            }
            return names
        }
    }

    func normalizeEquipment() throws {
        try dbQueue.write { db in try Self.normalizeEquipmentState(db) }
    }

    // MARK: - Register

    func createEquipment(_ item: EquipmentItem, date: Date = Date()) throws {
        try dbQueue.write { db in
            let now = SQLiteDateCoding.string(from: date)
            try db.execute(
                sql: """
                INSERT INTO equipment_items
                  (id, owner_id, item, category, identifier, serial_number, notes,
                   issued_to, location, issued_at, returned_at, status, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, 'available', ?)
                """,
                arguments: [
                    item.id.uuidString, userId.uuidString, item.item, item.category,
                    item.identifier, item.serialNumber, item.notes, now
                ]
            )
            try Self.insertEquipmentEvent(
                EquipmentEvent(date: date, type: .created, notes: item.notes),
                equipmentId: item.id,
                db: db
            )
        }
    }

    func updateEquipmentDetails(_ item: EquipmentItem) throws {
        try dbQueue.write { db in
            _ = try lockedItem(item.id, db: db)
            try db.execute(
                sql: """
                UPDATE equipment_items
                SET item = ?, category = ?, identifier = ?, serial_number = ?, notes = ?, updated_at = ?
                WHERE id = ? AND owner_id = ?
                """,
                arguments: [
                    item.item, item.category, item.identifier, item.serialNumber, item.notes,
                    SQLiteDateCoding.string(from: Date()), item.id.uuidString, userId.uuidString
                ]
            )
            try Self.insertEquipmentEvent(EquipmentEvent(type: .edited), equipmentId: item.id, db: db)
        }
    }

    /// Deletes the item with its checkouts and history.
    func deleteEquipment(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM equipment_items WHERE id = ? AND owner_id = ?",
                arguments: [id.uuidString, userId.uuidString]
            )
        }
    }

    // MARK: - Checkout lifecycle

    @discardableResult
    func issueEquipment(_ request: EquipmentIssueRequest) throws -> EquipmentCheckout {
        try dbQueue.write { db in
            let status = try lockedItem(request.equipmentId, db: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ?)",
                arguments: [request.projectId.uuidString]
            ) == true else {
                throw EquipmentActionError.invalidInput("The project is not available on this device.")
            }

            let recipientName = try resolveRecipientName(request, db: db)
            let location = EquipmentItem.nonEmpty(request.location)
            let notes = EquipmentItem.nonEmpty(request.notes)

            let active = try Self.activeCheckout(equipmentId: request.equipmentId, db: db)
            switch status {
            case .available, .returned:
                if active != nil { throw EquipmentActionError.inconsistent }
            case .issued:
                guard let active else { throw EquipmentActionError.inconsistent }
                guard request.handOver else {
                    throw EquipmentActionError.invalidState("Already issued to \(active.recipientName). Return it or hand it over.")
                }
                guard request.date >= active.issuedDate else {
                    throw EquipmentActionError.invalidInput("The hand-over date is before the current issue date.")
                }
                try close(active, at: request.date, outcome: .handedOver, notes: "Handed over to \(recipientName)", db: db)
                try Self.insertEquipmentEvent(
                    EquipmentEvent(
                        date: request.date, type: .handedOver, person: active.recipientName,
                        location: active.location, notes: "To \(recipientName)",
                        checkoutId: active.id, projectId: active.projectId
                    ),
                    equipmentId: request.equipmentId,
                    db: db
                )
            case .damaged, .lost:
                throw EquipmentActionError.invalidState("Put the item back in service before issuing it.")
            }

            let now = SQLiteDateCoding.string(from: Date())
            let checkout = EquipmentCheckout(
                id: UUID(),
                equipmentId: request.equipmentId,
                projectId: request.projectId,
                recipient: request.recipient,
                recipientName: recipientName,
                location: location,
                notes: notes,
                issuedDate: request.date
            )
            try db.execute(
                sql: """
                INSERT INTO equipment_checkouts
                  (id, equipment_id, project_id, recipient_kind, person_id, company_id, recipient_name,
                   location, notes, issued_at, returned_at, outcome, return_notes, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
                """,
                arguments: [
                    checkout.id.uuidString, checkout.equipmentId.uuidString, request.projectId.uuidString,
                    request.recipient.kind, checkout.personId?.uuidString, checkout.companyId?.uuidString,
                    recipientName, location, notes, SQLiteDateCoding.string(from: request.date), now, now
                ]
            )
            try Self.insertEquipmentEvent(
                EquipmentEvent(
                    date: request.date, type: .issued, person: recipientName, location: location,
                    notes: notes, checkoutId: checkout.id, projectId: request.projectId
                ),
                equipmentId: request.equipmentId,
                db: db
            )
            try db.execute(
                sql: """
                UPDATE equipment_items
                SET status = 'issued', issued_to = ?, location = ?, issued_at = ?, returned_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [recipientName, location, SQLiteDateCoding.string(from: request.date), now,
                            request.equipmentId.uuidString]
            )
            return checkout
        }
    }

    func returnEquipment(id: UUID, date: Date, condition: EquipmentReturnCondition, notes: String?) throws {
        try dbQueue.write { db in
            let status = try lockedItem(id, db: db)
            guard status == .issued else {
                throw EquipmentActionError.invalidState("Only issued items can be returned.")
            }
            guard let active = try Self.activeCheckout(equipmentId: id, db: db) else {
                throw EquipmentActionError.inconsistent
            }
            guard date >= active.issuedDate else {
                throw EquipmentActionError.invalidInput("The return date is before the issue date.")
            }
            let notes = EquipmentItem.nonEmpty(notes)
            let outcome: EquipmentCheckoutOutcome = condition == .damaged ? .damaged : .returned
            try close(active, at: date, outcome: outcome, notes: notes, db: db)
            try Self.insertEquipmentEvent(
                EquipmentEvent(
                    date: date, type: .returned, person: active.recipientName, location: active.location,
                    notes: notes, checkoutId: active.id, projectId: active.projectId
                ),
                equipmentId: id,
                db: db
            )
            if condition == .damaged {
                try Self.insertEquipmentEvent(
                    EquipmentEvent(
                        date: date, type: .markedDamaged, person: active.recipientName,
                        notes: "Returned damaged", checkoutId: active.id, projectId: active.projectId
                    ),
                    equipmentId: id,
                    db: db
                )
            }
            try setResting(id, status: condition == .damaged ? .damaged : .available, returnedAt: date, db: db)
        }
    }

    /// Marks an item damaged or lost. An open checkout is closed with the same outcome so
    /// the history keeps who had it.
    func markEquipment(id: UUID, status newStatus: EquipmentStatus, date: Date = Date(), notes: String?) throws {
        guard newStatus == .damaged || newStatus == .lost else {
            throw EquipmentActionError.invalidInput("Only damaged or lost can be set this way.")
        }
        try dbQueue.write { db in
            let status = try lockedItem(id, db: db)
            guard status != newStatus else {
                throw EquipmentActionError.invalidState("The item is already marked \(newStatus.label.lowercased()).")
            }
            let notes = EquipmentItem.nonEmpty(notes)
            let active = try Self.activeCheckout(equipmentId: id, db: db)
            if let active {
                let closeDate = max(date, active.issuedDate)
                try close(active, at: closeDate, outcome: newStatus == .lost ? .lost : .damaged, notes: notes, db: db)
            }
            try Self.insertEquipmentEvent(
                EquipmentEvent(
                    date: date,
                    type: newStatus == .damaged ? .markedDamaged : .markedLost,
                    person: active?.recipientName,
                    location: active?.location,
                    notes: notes,
                    checkoutId: active?.id,
                    projectId: active?.projectId
                ),
                equipmentId: id,
                db: db
            )
            try setResting(id, status: newStatus, returnedAt: active == nil ? nil : date, db: db)
        }
    }

    /// Puts a damaged / lost item back into service.
    func restoreEquipment(id: UUID, date: Date = Date(), notes: String?) throws {
        try dbQueue.write { db in
            let status = try lockedItem(id, db: db)
            guard status == .damaged || status == .lost else {
                throw EquipmentActionError.invalidState("Only damaged or lost items can be put back in service.")
            }
            try Self.insertEquipmentEvent(
                EquipmentEvent(date: date, type: .markedAvailable, notes: notes),
                equipmentId: id,
                db: db
            )
            try setResting(id, status: .available, returnedAt: nil, db: db)
        }
    }

    // MARK: - Private

    /// Current status of an owned item; throws when missing.
    private func lockedItem(_ id: UUID, db: Database) throws -> EquipmentStatus {
        guard let raw = try String.fetchOne(
            db,
            sql: "SELECT status FROM equipment_items WHERE id = ? AND owner_id = ?",
            arguments: [id.uuidString, userId.uuidString]
        ) else {
            throw EquipmentActionError.notFound
        }
        return EquipmentStatus(rawValue: raw) ?? .available
    }

    /// Contacts must belong to the user and be linked to the project the item is issued in.
    private func resolveRecipientName(_ request: EquipmentIssueRequest, db: Database) throws -> String {
        let project = request.projectId.uuidString
        switch request.recipient {
        case .freeText:
            guard let name = EquipmentItem.nonEmpty(request.recipientName) else {
                throw EquipmentActionError.invalidInput("Enter who receives the equipment.")
            }
            return name
        case .person(let personId):
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT p.first_name, p.last_name FROM contact_people p
                JOIN project_contacts pc ON pc.person_id = p.id AND pc.project_id = ?
                WHERE p.id = ? AND p.owner_id = ?
                """,
                arguments: [project, personId.uuidString, userId.uuidString]
            ) else {
                throw EquipmentActionError.invalidInput("This person is not in the project contacts.")
            }
            let first: String = row["first_name"]
            let last: String = row["last_name"]
            return [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        case .company(let companyId):
            guard let name = try String.fetchOne(
                db,
                sql: """
                SELECT c.name FROM contact_companies c
                JOIN project_contacts pc ON pc.company_id = c.id AND pc.project_id = ?
                WHERE c.id = ? AND c.owner_id = ?
                """,
                arguments: [project, companyId.uuidString, userId.uuidString]
            ) else {
                throw EquipmentActionError.invalidInput("This company is not in the project contacts.")
            }
            return name
        }
    }

    private func close(
        _ checkout: EquipmentCheckout,
        at date: Date,
        outcome: EquipmentCheckoutOutcome,
        notes: String?,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE equipment_checkouts
            SET returned_at = ?, outcome = ?, return_notes = ?, updated_at = ?
            WHERE id = ? AND returned_at IS NULL
            """,
            arguments: [SQLiteDateCoding.string(from: date), outcome.rawValue, notes,
                        SQLiteDateCoding.string(from: Date()), checkout.id.uuidString]
        )
        guard db.changesCount == 1 else { throw EquipmentActionError.inconsistent }
    }

    private func setResting(_ id: UUID, status: EquipmentStatus, returnedAt: Date?, db: Database) throws {
        if let returnedAt {
            try db.execute(
                sql: """
                UPDATE equipment_items SET status = ?, issued_to = NULL, returned_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, SQLiteDateCoding.string(from: returnedAt),
                            SQLiteDateCoding.string(from: Date()), id.uuidString]
            )
        } else {
            try db.execute(
                sql: "UPDATE equipment_items SET status = ?, issued_to = NULL, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, SQLiteDateCoding.string(from: Date()), id.uuidString]
            )
        }
    }

    static func activeCheckout(equipmentId: UUID, db: Database) throws -> EquipmentCheckout? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM equipment_checkouts WHERE equipment_id = ? AND returned_at IS NULL",
            arguments: [equipmentId.uuidString]
        ).map(checkout(from:))
    }

    static func insertEquipmentEvent(_ event: EquipmentEvent, equipmentId: UUID, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO equipment_events
              (id, equipment_id, event_at, event_type, person, location, notes, checkout_id, project_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                event.id.uuidString, equipmentId.uuidString, SQLiteDateCoding.string(from: event.date),
                event.type.rawValue, event.person, event.location, event.notes,
                event.checkoutId?.uuidString, event.projectId?.uuidString
            ]
        )
    }

    static func checkout(from row: Row) throws -> EquipmentCheckout {
        guard let id = UUID(uuidString: row["id"]),
              let equipmentId = UUID(uuidString: row["equipment_id"]) else {
            throw UserSharedMetadataStoreError.invalidRow("equipment_checkouts")
        }
        let kind: String = row["recipient_kind"]
        let personRaw: String? = row["person_id"]
        let companyRaw: String? = row["company_id"]
        let recipient: EquipmentRecipient
        if kind == "person", let personId = personRaw.flatMap(UUID.init(uuidString:)) {
            recipient = .person(personId)
        } else if kind == "company", let companyId = companyRaw.flatMap(UUID.init(uuidString:)) {
            recipient = .company(companyId)
        } else {
            // Free text, or a contact that has since been deleted (name snapshot remains).
            recipient = .freeText
        }
        let projectRaw: String? = row["project_id"]
        let issuedRaw: String = row["issued_at"]
        let returnedRaw: String? = row["returned_at"]
        let outcomeRaw: String? = row["outcome"]
        return EquipmentCheckout(
            id: id,
            equipmentId: equipmentId,
            projectId: projectRaw.flatMap(UUID.init(uuidString:)),
            recipient: recipient,
            recipientName: row["recipient_name"],
            location: row["location"],
            notes: row["notes"],
            issuedDate: SQLiteDateCoding.date(from: issuedRaw) ?? Date(),
            returnedDate: returnedRaw.flatMap(SQLiteDateCoding.date(from:)),
            outcome: outcomeRaw.flatMap(EquipmentCheckoutOutcome.init(rawValue:)),
            returnNotes: row["return_notes"]
        )
    }
}

enum EquipmentActionError: LocalizedError, Equatable {
    case notFound
    case invalidState(String)
    case invalidInput(String)
    /// Item status and open checkout disagree; the write is refused.
    case inconsistent

    var errorDescription: String? {
        switch self {
        case .notFound: return "Equipment not found."
        case .invalidState(let message), .invalidInput(let message): return message
        case .inconsistent: return "The equipment record is inconsistent. Reopen the register and try again."
        }
    }
}
