import Foundation
import GRDB

extension AppDatabase {
    /// Checkout records linking user-owned equipment to a project and a holder.
    /// `equipment_items.status` / `issued_to` stay as the denormalized current state and are
    /// only changed together with checkout rows in one transaction.
    static func createEquipmentCheckoutsSchema(_ db: Database) throws {
        try db.alter(table: "equipment_items") { t in
            t.add(column: "serial_number", .text)
            t.add(column: "updated_at", .text)
        }

        try db.create(table: "equipment_checkouts") { t in
            t.column("id", .text).primaryKey()
            t.column("equipment_id", .text).notNull()
                .references("equipment_items", onDelete: .cascade)
            // Null for checkouts recorded before projects existed, or after a project is removed.
            t.column("project_id", .text)
                .references("projects", onDelete: .setNull)
            t.column("recipient_kind", .text).notNull()
            t.column("person_id", .text)
                .references("contact_people", onDelete: .setNull)
            t.column("company_id", .text)
                .references("contact_companies", onDelete: .setNull)
            // Snapshot of the holder's name; survives contact edits and deletion.
            t.column("recipient_name", .text).notNull()
            t.column("location", .text)
            t.column("notes", .text)
            t.column("issued_at", .text).notNull()
            t.column("returned_at", .text)
            t.column("outcome", .text)
            t.column("return_notes", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.check(sql: "recipient_kind IN ('person', 'company', 'text')")
            t.check(sql: "(returned_at IS NULL) = (outcome IS NULL)")
        }
        // At most one open checkout per item.
        try db.create(
            index: "equipment_checkouts_one_active",
            on: "equipment_checkouts",
            columns: ["equipment_id"],
            options: .unique,
            condition: Column("returned_at") == nil
        )
        try db.create(index: "equipment_checkouts_equipment_id", on: "equipment_checkouts", columns: ["equipment_id", "issued_at"])
        try db.create(index: "equipment_checkouts_project_id", on: "equipment_checkouts", columns: ["project_id"])
        try db.create(index: "equipment_checkouts_person_id", on: "equipment_checkouts", columns: ["person_id"])
        try db.create(index: "equipment_checkouts_company_id", on: "equipment_checkouts", columns: ["company_id"])

        try db.alter(table: "equipment_events") { t in
            t.add(column: "checkout_id", .text)
                .references("equipment_checkouts", onDelete: .setNull)
            t.add(column: "project_id", .text)
                .references("projects", onDelete: .setNull)
        }
        try db.create(index: "equipment_events_checkout_id", on: "equipment_events", columns: ["checkout_id"])

        try normalizeEquipmentState(db)
    }

    /// Brings pre-checkout equipment rows into the checkout model. Idempotent; also run after
    /// JSON import because the importer can insert legacy rows after migrations.
    ///  - `returned` becomes `available` (return is an event, not a resting state).
    ///  - `issued` items without an open checkout get one from `issued_to` / `issued_at`.
    ///  - open checkouts on items that are not `issued` are closed.
    static func normalizeEquipmentState(_ db: Database) throws {
        try db.execute(sql: "UPDATE equipment_items SET status = 'available' WHERE status = 'returned'")

        let now = SQLiteDateCoding.string(from: Date())
        let orphanIssued = try Row.fetchAll(
            db,
            sql: """
            SELECT i.id, i.issued_to, i.location, i.issued_at
            FROM equipment_items i
            WHERE i.status = 'issued'
              AND NOT EXISTS (
                SELECT 1 FROM equipment_checkouts c
                WHERE c.equipment_id = i.id AND c.returned_at IS NULL
              )
            """
        )
        for row in orphanIssued {
            let equipmentId: String = row["id"]
            let lastIssueEvent = try Row.fetchOne(
                db,
                sql: """
                SELECT id, event_at, person FROM equipment_events
                WHERE equipment_id = ? AND event_type = 'issued'
                ORDER BY event_at DESC LIMIT 1
                """,
                arguments: [equipmentId]
            )
            let issuedTo: String? = row["issued_to"]
            let eventPerson: String? = lastIssueEvent?["person"]
            let itemIssuedAt: String? = row["issued_at"]
            let eventAt: String? = lastIssueEvent?["event_at"]
            let issuedAt = itemIssuedAt ?? eventAt ?? now
            let location: String? = row["location"]
            let checkoutId = UUID().uuidString
            try db.execute(
                sql: """
                INSERT INTO equipment_checkouts
                  (id, equipment_id, project_id, recipient_kind, person_id, company_id, recipient_name,
                   location, notes, issued_at, returned_at, outcome, return_notes, created_at, updated_at)
                VALUES (?, ?, NULL, 'text', NULL, NULL, ?, ?, NULL, ?, NULL, NULL, NULL, ?, ?)
                """,
                arguments: [
                    checkoutId,
                    equipmentId,
                    issuedTo ?? eventPerson ?? "Unknown holder",
                    location,
                    issuedAt,
                    now,
                    now
                ]
            )
            if let eventId: String = lastIssueEvent?["id"] {
                try db.execute(
                    sql: "UPDATE equipment_events SET checkout_id = ? WHERE id = ? AND checkout_id IS NULL",
                    arguments: [checkoutId, eventId]
                )
            }
        }

        try db.execute(
            sql: """
            UPDATE equipment_checkouts
            SET returned_at = COALESCE(
                  (SELECT i.returned_at FROM equipment_items i WHERE i.id = equipment_checkouts.equipment_id),
                  ?),
                outcome = CASE
                  (SELECT i.status FROM equipment_items i WHERE i.id = equipment_checkouts.equipment_id)
                  WHEN 'damaged' THEN 'damaged'
                  WHEN 'lost' THEN 'lost'
                  ELSE 'returned' END,
                updated_at = ?
            WHERE returned_at IS NULL
              AND equipment_id IN (SELECT id FROM equipment_items WHERE status <> 'issued')
            """,
            arguments: [now, now]
        )
    }

    /// Project photo documentation. Image files live under `Projects/<projectId>/Photos/`;
    /// rows store paths relative to the project root. Local only until synchronized.
    static func createProjectPhotosSchema(_ db: Database) throws {
        try db.create(table: "photo_albums") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX photo_albums_project_name
            ON photo_albums (project_id, name COLLATE NOCASE)
            """)

        try db.create(table: "project_photos") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("album_id", .text)
                .references("photo_albums", onDelete: .setNull)
            // Relative to the project root, e.g. "Photos/<uuid>.jpg"
            t.column("file_name", .text).notNull()
            t.column("thumbnail_file_name", .text)
            t.column("title", .text)
            t.column("description", .text).notNull().defaults(to: "")
            t.column("taken_at", .text).notNull()
            t.column("drawing_id", .text)
                .references("drawings", onDelete: .setNull)
            t.column("page_index", .integer)
            t.column("area_id", .text)
                .references("areas", onDelete: .setNull)
            t.column("issue_id", .text)
                .references("issues", onDelete: .setNull)
            t.column("pixel_width", .integer)
            t.column("pixel_height", .integer)
            t.column("byte_size", .integer)
            // 'local_only' until a sync slice uploads the file and metadata.
            t.column("sync_status", .text).notNull().defaults(to: "local_only")
            t.column("remote_storage_path", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "project_photos_project_taken", on: "project_photos", columns: ["project_id", "taken_at"])
        try db.create(index: "project_photos_album_id", on: "project_photos", columns: ["album_id"])
        try db.create(index: "project_photos_issue_id", on: "project_photos", columns: ["issue_id"])
        try db.create(index: "project_photos_drawing_id", on: "project_photos", columns: ["drawing_id"])
        try db.create(index: "project_photos_area_id", on: "project_photos", columns: ["area_id"])
    }
}
