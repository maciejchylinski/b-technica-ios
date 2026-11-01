import Foundation
import GRDB

extension AppDatabase {
    /// Initial local schema: project-scoped entities, user-global dictionaries,
    /// and sync scaffolding (`sync_outbox`, `sync_state`, `file_transfers` for PDF uploads).
    static func createV1Schema(_ db: Database) throws {
        // MARK: Project-scoped

        try db.create(table: "projects") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "drawing_folders") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("parent_folder_id", .text)
            t.column("name", .text).notNull()
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "drawing_folders_project_id", on: "drawing_folders", columns: ["project_id"])

        try db.create(table: "drawings") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("folder_id", .text)
            t.column("name", .text).notNull()
            // Relative basename under Projects/<id>/Drawings/ (e.g. "<uuid>.pdf")
            t.column("file_name", .text).notNull()
            t.column("page_count", .integer).notNull()
            t.column("created_at", .text).notNull()
            t.column("revision", .text)
            t.column("discipline", .text)
            t.column("location", .text)
            t.column("drawing_date", .text)
        }
        try db.create(index: "drawings_project_id", on: "drawings", columns: ["project_id"])

        try db.create(table: "page_calibrations") { t in
            t.column("id", .text).primaryKey()
            t.column("drawing_id", .text).notNull()
                .references("drawings", onDelete: .cascade)
            t.column("page_index", .integer).notNull()
            t.column("point_a_x", .double).notNull()
            t.column("point_a_y", .double).notNull()
            t.column("point_b_x", .double).notNull()
            t.column("point_b_y", .double).notNull()
            t.column("real_distance_mm", .double).notNull()
            t.column("entered_unit", .text).notNull()
            t.column("entered_value", .double).notNull()
            t.column("mm_per_pdf_unit", .double).notNull()
            t.column("calibrated_at", .text).notNull()
        }
        try db.create(index: "page_calibrations_drawing_id", on: "page_calibrations", columns: ["drawing_id"])

        try db.create(table: "areas") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("drawing_id", .text).notNull()
                .references("drawings", onDelete: .cascade)
            t.column("page_index", .integer).notNull()
            t.column("name", .text).notNull()
            // JSON array of {x,y} PDF page coordinates
            t.column("vertices_json", .text).notNull()
            t.column("color", .text).notNull()
            t.column("opacity", .double).notNull()
            t.column("is_visible", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "areas_project_id", on: "areas", columns: ["project_id"])
        try db.create(index: "areas_drawing_id", on: "areas", columns: ["drawing_id"])

        try db.create(table: "issues") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("drawing_id", .text).notNull()
                .references("drawings", onDelete: .cascade)
            t.column("page_index", .integer).notNull()
            t.column("pdf_x", .double).notNull()
            t.column("pdf_y", .double).notNull()
            t.column("area_id", .text)
            t.column("number", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("details", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull()
            t.column("discipline", .text)
            t.column("contractor", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "issues_project_id", on: "issues", columns: ["project_id"])
        try db.create(index: "issues_drawing_id", on: "issues", columns: ["drawing_id"])

        try db.create(table: "issue_photos") { t in
            t.column("id", .text).primaryKey()
            t.column("issue_id", .text).notNull()
                .references("issues", onDelete: .cascade)
            // Relative basename under Projects/<id>/IssuePhotos/
            t.column("file_name", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "issue_photos_issue_id", on: "issue_photos", columns: ["issue_id"])

        // MARK: User-global

        try db.create(table: "contractors") { t in
            t.column("id", .text).primaryKey()
            t.column("owner_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("notes", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "contractors_owner_id", on: "contractors", columns: ["owner_id"])

        try db.create(table: "disciplines") { t in
            t.column("id", .text).primaryKey()
            t.column("owner_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(index: "disciplines_owner_id", on: "disciplines", columns: ["owner_id"])

        try db.create(table: "equipment_items") { t in
            t.column("id", .text).primaryKey()
            t.column("owner_id", .text).notNull()
            t.column("item", .text).notNull()
            t.column("category", .text)
            t.column("identifier", .text)
            t.column("notes", .text)
            t.column("issued_to", .text)
            t.column("location", .text)
            t.column("issued_at", .text)
            t.column("returned_at", .text)
            t.column("status", .text).notNull()
        }
        try db.create(index: "equipment_items_owner_id", on: "equipment_items", columns: ["owner_id"])

        try db.create(table: "equipment_events") { t in
            t.column("id", .text).primaryKey()
            t.column("equipment_id", .text).notNull()
                .references("equipment_items", onDelete: .cascade)
            t.column("event_at", .text).notNull()
            t.column("event_type", .text).notNull()
            t.column("person", .text)
            t.column("location", .text)
            t.column("notes", .text)
        }
        try db.create(index: "equipment_events_equipment_id", on: "equipment_events", columns: ["equipment_id"])

        // MARK: Sync scaffolding (unused until later tasks)

        try db.create(table: "sync_outbox") { t in
            t.column("id", .text).primaryKey()
            t.column("entity_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("operation", .text).notNull()
            t.column("payload_json", .text)
            t.column("created_at", .text).notNull()
            t.column("attempt_count", .integer).notNull().defaults(to: 0)
            t.column("last_error", .text)
            t.column("next_attempt_at", .text)
        }
        try db.create(
            index: "sync_outbox_entity",
            on: "sync_outbox",
            columns: ["entity_type", "entity_id"]
        )

        try db.create(table: "sync_state") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
            t.column("updated_at", .text).notNull()
        }

        try db.create(table: "file_transfers") { t in
            t.column("id", .text).primaryKey()
            t.column("entity_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("local_relative_path", .text).notNull()
            t.column("remote_path", .text)
            t.column("direction", .text).notNull()
            t.column("status", .text).notNull()
            t.column("bytes_total", .integer)
            t.column("bytes_done", .integer).notNull().defaults(to: 0)
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(
            index: "file_transfers_status",
            on: "file_transfers",
            columns: ["status"]
        )

        // Tracks which JSON sources have been imported (idempotent marker + audit).
        try db.create(table: "json_import_runs") { t in
            t.column("source_key", .text).primaryKey()
            t.column("source_path", .text).notNull()
            t.column("imported_at", .text).notNull()
            t.column("record_counts_json", .text).notNull()
        }
    }
}
