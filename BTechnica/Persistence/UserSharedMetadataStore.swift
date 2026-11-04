import Foundation
import GRDB

/// SQLite read/write for user-global contractors, disciplines, equipment, and history.
/// Rows are scoped by `owner_id` = authenticated user. JSON `userdata.json` is recovery-only.
extension AppDatabase {
    func fetchContractors() throws -> [Contractor] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, notes, created_at
                FROM contractors
                WHERE owner_id = ?
                ORDER BY name ASC, created_at ASC
                """,
                arguments: [userId.uuidString]
            )
            return try rows.map { try Self.contractor(from: $0) }
        }
    }

    func fetchDisciplines() throws -> [Discipline] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, created_at
                FROM disciplines
                WHERE owner_id = ?
                ORDER BY name ASC, created_at ASC
                """,
                arguments: [userId.uuidString]
            )
            return try rows.map { try Self.discipline(from: $0) }
        }
    }

    func fetchEquipment() throws -> [EquipmentItem] {
        try dbQueue.read { db in
            let itemRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, item, category, identifier, serial_number, notes, issued_to, location,
                       issued_at, returned_at, status
                FROM equipment_items
                WHERE owner_id = ?
                ORDER BY item ASC, id ASC
                """,
                arguments: [userId.uuidString]
            )
            var result: [EquipmentItem] = []
            result.reserveCapacity(itemRows.count)
            for row in itemRows {
                var item = try Self.equipmentItem(from: row)
                item.history = try Self.fetchEquipmentEvents(equipmentId: item.id, db: db)
                result.append(item)
            }
            return result
        }
    }

    /// Atomically persists user-global dictionaries and, when `equipment` is non-nil,
    /// replaces equipment (incl. history). Pass nil to leave equipment untouched; the app
    /// writes equipment through the targeted checkout API in `EquipmentMetadataStore`.
    /// Preserves UUIDs; scoped to this database's `userId` as `owner_id`.
    func persistUserShared(
        contractors: [Contractor],
        disciplines: [Discipline],
        equipment: [EquipmentItem]?
    ) throws {
        try dbQueue.write { db in
            let owner = userId.uuidString
            let keepContractorIds = Set(contractors.map(\.id.uuidString))
            let keepDisciplineIds = Set(disciplines.map(\.id.uuidString))

            for c in contractors {
                try db.execute(
                    sql: """
                    INSERT INTO contractors (id, owner_id, name, notes, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_id = excluded.owner_id,
                      name = excluded.name,
                      notes = excluded.notes,
                      created_at = excluded.created_at
                    """,
                    arguments: [
                        c.id.uuidString,
                        owner,
                        c.name,
                        c.notes,
                        SQLiteDateCoding.string(from: c.createdDate)
                    ]
                )
            }

            for d in disciplines {
                try db.execute(
                    sql: """
                    INSERT INTO disciplines (id, owner_id, name, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_id = excluded.owner_id,
                      name = excluded.name,
                      created_at = excluded.created_at
                    """,
                    arguments: [
                        d.id.uuidString,
                        owner,
                        d.name,
                        SQLiteDateCoding.string(from: d.createdDate)
                    ]
                )
            }

            for item in equipment ?? [] {
                try db.execute(
                    sql: """
                    INSERT INTO equipment_items
                      (id, owner_id, item, category, identifier, notes,
                       issued_to, location, issued_at, returned_at, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_id = excluded.owner_id,
                      item = excluded.item,
                      category = excluded.category,
                      identifier = excluded.identifier,
                      notes = excluded.notes,
                      issued_to = excluded.issued_to,
                      location = excluded.location,
                      issued_at = excluded.issued_at,
                      returned_at = excluded.returned_at,
                      status = excluded.status
                    """,
                    arguments: [
                        item.id.uuidString,
                        owner,
                        item.item,
                        item.category,
                        item.identifier,
                        item.notes,
                        item.issuedTo,
                        item.location,
                        item.issuedDate.map(SQLiteDateCoding.string(from:)),
                        item.returnedDate.map(SQLiteDateCoding.string(from:)),
                        item.status.rawValue
                    ]
                )

                let keepEventIds = Set(item.history.map(\.id.uuidString))
                for event in item.history {
                    try db.execute(
                        sql: """
                        INSERT INTO equipment_events
                          (id, equipment_id, event_at, event_type, person, location, notes)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          equipment_id = excluded.equipment_id,
                          event_at = excluded.event_at,
                          event_type = excluded.event_type,
                          person = excluded.person,
                          location = excluded.location,
                          notes = excluded.notes
                        """,
                        arguments: [
                            event.id.uuidString,
                            item.id.uuidString,
                            SQLiteDateCoding.string(from: event.date),
                            event.type.rawValue,
                            event.person,
                            event.location,
                            event.notes
                        ]
                    )
                }

                let existingEventIds = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM equipment_events WHERE equipment_id = ?",
                    arguments: [item.id.uuidString]
                )
                for id in existingEventIds where !keepEventIds.contains(id) {
                    try db.execute(sql: "DELETE FROM equipment_events WHERE id = ?", arguments: [id])
                }
            }

            // Orphans: equipment first (events cascade), then dictionaries.
            if let equipment {
                let keepEquipmentIds = Set(equipment.map(\.id.uuidString))
                let existingEquipment = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM equipment_items WHERE owner_id = ?",
                    arguments: [owner]
                )
                for id in existingEquipment where !keepEquipmentIds.contains(id) {
                    try db.execute(sql: "DELETE FROM equipment_items WHERE id = ?", arguments: [id])
                }
            }

            let existingContractors = try String.fetchAll(
                db,
                sql: "SELECT id FROM contractors WHERE owner_id = ?",
                arguments: [owner]
            )
            for id in existingContractors where !keepContractorIds.contains(id) {
                try db.execute(sql: "DELETE FROM contractors WHERE id = ?", arguments: [id])
            }

            let existingDisciplines = try String.fetchAll(
                db,
                sql: "SELECT id FROM disciplines WHERE owner_id = ?",
                arguments: [owner]
            )
            for id in existingDisciplines where !keepDisciplineIds.contains(id) {
                try db.execute(sql: "DELETE FROM disciplines WHERE id = ?", arguments: [id])
            }
        }
    }

    // MARK: - Row mapping

    private static func contractor(from row: Row) throws -> Contractor {
        guard let id = UUID(uuidString: row["id"]) else {
            throw UserSharedMetadataStoreError.invalidRow("contractors")
        }
        let createdRaw: String = row["created_at"]
        return Contractor(
            id: id,
            name: row["name"],
            notes: row["notes"],
            createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date()
        )
    }

    private static func discipline(from row: Row) throws -> Discipline {
        guard let id = UUID(uuidString: row["id"]) else {
            throw UserSharedMetadataStoreError.invalidRow("disciplines")
        }
        let createdRaw: String = row["created_at"]
        return Discipline(
            id: id,
            name: row["name"],
            createdDate: SQLiteDateCoding.date(from: createdRaw) ?? Date()
        )
    }

    static func equipmentItem(from row: Row) throws -> EquipmentItem {
        guard let id = UUID(uuidString: row["id"]) else {
            throw UserSharedMetadataStoreError.invalidRow("equipment_items")
        }
        let statusRaw: String = row["status"]
        let issuedRaw: String? = row["issued_at"]
        let returnedRaw: String? = row["returned_at"]
        return EquipmentItem(
            id: id,
            item: row["item"],
            category: row["category"],
            identifier: row["identifier"],
            serialNumber: row["serial_number"],
            notes: row["notes"],
            issuedTo: row["issued_to"],
            location: row["location"],
            issuedDate: issuedRaw.flatMap(SQLiteDateCoding.date(from:)),
            returnedDate: returnedRaw.flatMap(SQLiteDateCoding.date(from:)),
            status: EquipmentStatus(rawValue: statusRaw) ?? .available,
            history: []
        )
    }

    static func fetchEquipmentEvents(equipmentId: UUID, db: Database) throws -> [EquipmentEvent] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, event_at, event_type, person, location, notes, checkout_id, project_id
            FROM equipment_events
            WHERE equipment_id = ?
            ORDER BY event_at ASC, id ASC
            """,
            arguments: [equipmentId.uuidString]
        )
        return try rows.map { row in
            guard let id = UUID(uuidString: row["id"]) else {
                throw UserSharedMetadataStoreError.invalidRow("equipment_events")
            }
            let typeRaw: String = row["event_type"]
            let atRaw: String = row["event_at"]
            let checkoutRaw: String? = row["checkout_id"]
            let projectRaw: String? = row["project_id"]
            return EquipmentEvent(
                id: id,
                date: SQLiteDateCoding.date(from: atRaw) ?? Date(),
                type: EquipmentEventType(rawValue: typeRaw) ?? .edited,
                person: row["person"],
                location: row["location"],
                notes: row["notes"],
                checkoutId: checkoutRaw.flatMap(UUID.init(uuidString:)),
                projectId: projectRaw.flatMap(UUID.init(uuidString:))
            )
        }
    }
}

enum UserSharedMetadataStoreError: LocalizedError {
    case invalidRow(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            return "Invalid SQLite row in \(table)"
        }
    }
}
