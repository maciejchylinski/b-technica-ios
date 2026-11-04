import Foundation
import GRDB

extension AppDatabase {
    /// Construction schedule (additive). One schedule per project; phases, tasks and
    /// finish-to-start dependencies hang off it.
    ///
    /// Composite foreign keys carry `project_id` / `schedule_id` down the tree so a row
    /// can never reference a schedule, phase or task from another project or schedule.
    /// Calendar days are `yyyy-MM-dd` TEXT (no time zone).
    static func createConstructionScheduleSchema(_ db: Database) throws {
        try db.create(table: "schedules") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("details", .text).notNull().defaults(to: "")
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.uniqueKey(["id", "project_id"])
            t.check(sql: "length(trim(name)) > 0")
        }
        try db.create(index: "schedules_project_id", on: "schedules", columns: ["project_id"], options: .unique)

        try db.create(table: "schedule_phases") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
            t.column("schedule_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("color", .text).notNull().defaults(to: "#1C7AE6")
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.foreignKey(
                ["schedule_id", "project_id"],
                references: "schedules",
                columns: ["id", "project_id"],
                onDelete: .cascade
            )
            t.uniqueKey(["id", "schedule_id"])
            t.check(sql: "length(trim(name)) > 0")
        }
        try db.create(index: "schedule_phases_schedule_id", on: "schedule_phases", columns: ["schedule_id", "sort_order"])
        try db.create(index: "schedule_phases_project_id", on: "schedule_phases", columns: ["project_id"])

        try db.create(table: "schedule_tasks") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
            t.column("schedule_id", .text).notNull()
            t.column("phase_id", .text)
            t.column("kind", .text).notNull().defaults(to: "task")
            t.column("title", .text).notNull()
            t.column("details", .text).notNull().defaults(to: "")
            t.column("start_date", .text).notNull()
            t.column("finish_date", .text).notNull()
            t.column("progress", .integer).notNull().defaults(to: 0)
            t.column("status", .text).notNull().defaults(to: "planned")
            t.column("responsible_name", .text)
            // Future link to project contacts; intentionally no FK until that module lands.
            t.column("responsible_contact_id", .text)
            t.column("notes", .text).notNull().defaults(to: "")
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.foreignKey(
                ["schedule_id", "project_id"],
                references: "schedules",
                columns: ["id", "project_id"],
                onDelete: .cascade
            )
            // NULL phase_id skips this check (task without a phase).
            t.foreignKey(
                ["phase_id", "schedule_id"],
                references: "schedule_phases",
                columns: ["id", "schedule_id"],
                onDelete: .cascade
            )
            t.uniqueKey(["id", "schedule_id"])
            t.check(sql: "length(trim(title)) > 0")
            t.check(sql: "kind IN ('task', 'milestone')")
            t.check(sql: "status IN ('planned', 'inProgress', 'completed', 'delayed')")
            t.check(sql: "progress BETWEEN 0 AND 100")
            t.check(sql: "start_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'")
            t.check(sql: "finish_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'")
            // ISO dates compare correctly as text.
            t.check(sql: "finish_date >= start_date")
            t.check(sql: "kind <> 'milestone' OR finish_date = start_date")
            t.check(sql: "status <> 'completed' OR progress = 100")
        }
        try db.create(index: "schedule_tasks_schedule_id", on: "schedule_tasks", columns: ["schedule_id", "start_date"])
        try db.create(index: "schedule_tasks_phase_id", on: "schedule_tasks", columns: ["phase_id", "sort_order"])
        try db.create(index: "schedule_tasks_project_id", on: "schedule_tasks", columns: ["project_id"])

        try db.create(table: "schedule_task_dependencies") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
            t.column("schedule_id", .text).notNull()
            t.column("predecessor_task_id", .text).notNull()
            t.column("successor_task_id", .text).notNull()
            t.column("dependency_type", .text).notNull().defaults(to: "finish_to_start")
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.foreignKey(
                ["schedule_id", "project_id"],
                references: "schedules",
                columns: ["id", "project_id"],
                onDelete: .cascade
            )
            t.foreignKey(
                ["predecessor_task_id", "schedule_id"],
                references: "schedule_tasks",
                columns: ["id", "schedule_id"],
                onDelete: .cascade
            )
            t.foreignKey(
                ["successor_task_id", "schedule_id"],
                references: "schedule_tasks",
                columns: ["id", "schedule_id"],
                onDelete: .cascade
            )
            t.uniqueKey(["predecessor_task_id", "successor_task_id"])
            t.check(sql: "predecessor_task_id <> successor_task_id")
            t.check(sql: "dependency_type IN ('finish_to_start')")
        }
        try db.create(
            index: "schedule_task_dependencies_schedule_id",
            on: "schedule_task_dependencies",
            columns: ["schedule_id"]
        )
        try db.create(
            index: "schedule_task_dependencies_successor",
            on: "schedule_task_dependencies",
            columns: ["successor_task_id"]
        )
    }
}
