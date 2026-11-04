import Foundation
import GRDB

/// SQLite read/write for construction schedules.
///
/// Every mutation runs in a single `dbQueue.write` transaction; a thrown validation
/// error rolls back the whole change. Every statement is scoped by `project_id`, and
/// upserts refuse to move an existing row to another project or schedule.
extension AppDatabase {
    // MARK: - Read

    func fetchScheduleSnapshot(projectId: UUID) throws -> ScheduleSnapshot {
        try dbQueue.read { db in
            guard let scheduleRow = try Row.fetchOne(
                db,
                sql: """
                SELECT id, project_id, name, details, created_at, updated_at
                FROM schedules WHERE project_id = ?
                """,
                arguments: [projectId.uuidString]
            ) else {
                return .empty
            }
            let schedule = try Self.schedule(from: scheduleRow)
            let scheduleId = schedule.id.uuidString

            let phases = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, schedule_id, name, color, sort_order, created_at, updated_at
                FROM schedule_phases
                WHERE schedule_id = ? AND project_id = ?
                ORDER BY sort_order ASC, created_at ASC
                """,
                arguments: [scheduleId, projectId.uuidString]
            ).map(Self.phase(from:))

            let tasks = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, schedule_id, phase_id, kind, title, details,
                       start_date, finish_date, progress, status, responsible_name,
                       responsible_contact_id, notes, sort_order, created_at, updated_at
                FROM schedule_tasks
                WHERE schedule_id = ? AND project_id = ?
                ORDER BY sort_order ASC, start_date ASC, created_at ASC
                """,
                arguments: [scheduleId, projectId.uuidString]
            ).map(Self.task(from:))

            let dependencies = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, schedule_id, predecessor_task_id, successor_task_id,
                       dependency_type, created_at, updated_at
                FROM schedule_task_dependencies
                WHERE schedule_id = ? AND project_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [scheduleId, projectId.uuidString]
            ).map(Self.dependency(from:))

            return ScheduleSnapshot(
                schedule: schedule,
                phases: phases,
                tasks: tasks,
                dependencies: dependencies
            )
        }
    }

    // MARK: - Schedule

    func createSchedule(_ schedule: ConstructionSchedule) throws {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduleValidationError.emptyScheduleName }
        try dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM schedules WHERE project_id = ?)",
                arguments: [schedule.projectId.uuidString]
            ) ?? false
            if exists { throw ScheduleValidationError.scheduleAlreadyExists }
            try db.execute(
                sql: """
                INSERT INTO schedules (id, project_id, name, details, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    schedule.id.uuidString,
                    schedule.projectId.uuidString,
                    name,
                    schedule.details.trimmingCharacters(in: .whitespacesAndNewlines),
                    SQLiteDateCoding.string(from: schedule.createdAt),
                    SQLiteDateCoding.string(from: schedule.updatedAt)
                ]
            )
        }
    }

    func updateSchedule(_ schedule: ConstructionSchedule) throws {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduleValidationError.emptyScheduleName }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE schedules SET name = ?, details = ?, updated_at = ?
                WHERE id = ? AND project_id = ?
                """,
                arguments: [
                    name,
                    schedule.details.trimmingCharacters(in: .whitespacesAndNewlines),
                    SQLiteDateCoding.string(from: schedule.updatedAt),
                    schedule.id.uuidString,
                    schedule.projectId.uuidString
                ]
            )
            if db.changesCount == 0 { throw ScheduleValidationError.notFound }
        }
    }

    /// Removes the schedule with all phases, tasks and dependencies (FK cascade).
    func deleteSchedule(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM schedules WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    // MARK: - Phases

    func savePhase(_ phase: SchedulePhase) throws {
        let name = phase.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduleValidationError.emptyPhaseName }
        try dbQueue.write { db in
            try Self.requireSchedule(id: phase.scheduleId, projectId: phase.projectId, db: db)
            try db.execute(
                sql: """
                INSERT INTO schedule_phases
                  (id, project_id, schedule_id, name, color, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  color = excluded.color,
                  sort_order = excluded.sort_order,
                  updated_at = excluded.updated_at
                WHERE schedule_phases.project_id = excluded.project_id
                  AND schedule_phases.schedule_id = excluded.schedule_id
                """,
                arguments: [
                    phase.id.uuidString,
                    phase.projectId.uuidString,
                    phase.scheduleId.uuidString,
                    name,
                    phase.colorHex,
                    phase.sortOrder,
                    SQLiteDateCoding.string(from: phase.createdAt),
                    SQLiteDateCoding.string(from: phase.updatedAt)
                ]
            )
            if db.changesCount == 0 { throw ScheduleValidationError.phaseNotInSchedule }
        }
    }

    /// Deletes the phase and its tasks (and their dependencies) via FK cascade.
    func deletePhase(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM schedule_phases WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    /// Rewrites `sort_order` for phases in the given order.
    func reorderPhases(_ orderedIds: [UUID], scheduleId: UUID, projectId: UUID, at date: Date) throws {
        try dbQueue.write { db in
            for (index, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: """
                    UPDATE schedule_phases SET sort_order = ?, updated_at = ?
                    WHERE id = ? AND schedule_id = ? AND project_id = ?
                    """,
                    arguments: [
                        index,
                        SQLiteDateCoding.string(from: date),
                        id.uuidString,
                        scheduleId.uuidString,
                        projectId.uuidString
                    ]
                )
            }
        }
    }

    // MARK: - Tasks

    /// Validates and upserts a task. When `predecessorIds` is non-nil, the task's
    /// incoming finish-to-start dependencies are replaced with exactly that set
    /// (cycle-checked against the whole schedule) in the same transaction.
    @discardableResult
    func saveTask(_ task: ScheduleTask, predecessorIds: [UUID]? = nil) throws -> ScheduleTask {
        let normalized = try ScheduleRules.normalized(task)
        try dbQueue.write { db in
            try Self.requireSchedule(id: normalized.scheduleId, projectId: normalized.projectId, db: db)
            if let phaseId = normalized.phaseId {
                let ok = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(SELECT 1 FROM schedule_phases
                                  WHERE id = ? AND schedule_id = ? AND project_id = ?)
                    """,
                    arguments: [phaseId.uuidString, normalized.scheduleId.uuidString, normalized.projectId.uuidString]
                ) ?? false
                guard ok else { throw ScheduleValidationError.phaseNotInSchedule }
            }

            try Self.upsertTask(normalized, db: db)
            if db.changesCount == 0 { throw ScheduleValidationError.taskNotInSchedule }

            if let predecessorIds {
                try Self.replacePredecessors(predecessorIds, of: normalized, db: db)
            }
        }
        return normalized
    }

    /// Deletes a task; dependencies touching it cascade.
    func deleteTask(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM schedule_tasks WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    /// Rewrites `sort_order` for tasks in the given order (typically one phase).
    func reorderTasks(_ orderedIds: [UUID], scheduleId: UUID, projectId: UUID, at date: Date) throws {
        try dbQueue.write { db in
            for (index, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: """
                    UPDATE schedule_tasks SET sort_order = ?, updated_at = ?
                    WHERE id = ? AND schedule_id = ? AND project_id = ?
                    """,
                    arguments: [
                        index,
                        SQLiteDateCoding.string(from: date),
                        id.uuidString,
                        scheduleId.uuidString,
                        projectId.uuidString
                    ]
                )
            }
        }
    }

    // MARK: - Dependencies

    func addDependency(_ dependency: ScheduleDependency) throws {
        try dbQueue.write { db in
            try Self.requireSchedule(id: dependency.scheduleId, projectId: dependency.projectId, db: db)
            try Self.requireTasks(
                [dependency.predecessorId, dependency.successorId],
                scheduleId: dependency.scheduleId,
                db: db
            )
            let edges = try Self.edges(scheduleId: dependency.scheduleId, db: db)
            let candidate = ScheduleRules.Edge(
                predecessor: dependency.predecessorId,
                successor: dependency.successorId
            )
            if candidate.predecessor == candidate.successor {
                throw ScheduleValidationError.selfDependency
            }
            if edges.contains(candidate) { throw ScheduleValidationError.duplicateDependency }
            if ScheduleRules.wouldCreateCycle(adding: candidate, to: edges) {
                throw ScheduleValidationError.circularDependency
            }
            try Self.insertDependency(dependency, db: db)
        }
    }

    func deleteDependency(id: UUID, projectId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM schedule_task_dependencies WHERE id = ? AND project_id = ?",
                arguments: [id.uuidString, projectId.uuidString]
            )
        }
    }

    // MARK: - Writers

    private static func requireSchedule(id: UUID, projectId: UUID, db: Database) throws {
        let ok = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM schedules WHERE id = ? AND project_id = ?)",
            arguments: [id.uuidString, projectId.uuidString]
        ) ?? false
        guard ok else { throw ScheduleValidationError.notFound }
    }

    private static func requireTasks(_ ids: [UUID], scheduleId: UUID, db: Database) throws {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ", ")
        var arguments: [(any DatabaseValueConvertible)?] = [scheduleId.uuidString]
        arguments.append(contentsOf: unique.map(\.uuidString))
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM schedule_tasks WHERE schedule_id = ? AND id IN (\(placeholders))",
            arguments: StatementArguments(arguments)
        ) ?? 0
        guard count == unique.count else { throw ScheduleValidationError.taskNotInSchedule }
    }

    private static func edges(scheduleId: UUID, db: Database) throws -> [ScheduleRules.Edge] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT predecessor_task_id, successor_task_id
            FROM schedule_task_dependencies WHERE schedule_id = ?
            """,
            arguments: [scheduleId.uuidString]
        ).map { row in
            ScheduleRules.Edge(
                predecessor: try uuid(row, "predecessor_task_id"),
                successor: try uuid(row, "successor_task_id")
            )
        }
    }

    private static func upsertTask(_ task: ScheduleTask, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO schedule_tasks
              (id, project_id, schedule_id, phase_id, kind, title, details,
               start_date, finish_date, progress, status, responsible_name,
               responsible_contact_id, notes, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              phase_id = excluded.phase_id,
              kind = excluded.kind,
              title = excluded.title,
              details = excluded.details,
              start_date = excluded.start_date,
              finish_date = excluded.finish_date,
              progress = excluded.progress,
              status = excluded.status,
              responsible_name = excluded.responsible_name,
              responsible_contact_id = excluded.responsible_contact_id,
              notes = excluded.notes,
              sort_order = excluded.sort_order,
              updated_at = excluded.updated_at
            WHERE schedule_tasks.project_id = excluded.project_id
              AND schedule_tasks.schedule_id = excluded.schedule_id
            """,
            arguments: [
                task.id.uuidString,
                task.projectId.uuidString,
                task.scheduleId.uuidString,
                task.phaseId?.uuidString,
                task.kind.rawValue,
                task.title,
                task.details,
                task.startDay.isoString,
                task.finishDay.isoString,
                task.progress,
                task.status.rawValue,
                task.responsibleName,
                task.responsibleContactId?.uuidString,
                task.notes,
                task.sortOrder,
                SQLiteDateCoding.string(from: task.createdAt),
                SQLiteDateCoding.string(from: task.updatedAt)
            ]
        )
    }

    private static func replacePredecessors(_ predecessorIds: [UUID], of task: ScheduleTask, db: Database) throws {
        try requireTasks(predecessorIds, scheduleId: task.scheduleId, db: db)
        let edges = try edges(scheduleId: task.scheduleId, db: db)
        try ScheduleRules.validatePredecessors(predecessorIds, of: task.id, existing: edges)

        let wanted = Set(predecessorIds)
        let current = Set(edges.filter { $0.successor == task.id }.map(\.predecessor))
        for removed in current.subtracting(wanted) {
            try db.execute(
                sql: """
                DELETE FROM schedule_task_dependencies
                WHERE predecessor_task_id = ? AND successor_task_id = ? AND schedule_id = ?
                """,
                arguments: [removed.uuidString, task.id.uuidString, task.scheduleId.uuidString]
            )
        }
        for added in predecessorIds where !current.contains(added) {
            try insertDependency(
                ScheduleDependency(
                    id: UUID(),
                    projectId: task.projectId,
                    scheduleId: task.scheduleId,
                    predecessorId: added,
                    successorId: task.id,
                    type: .finishToStart,
                    createdAt: task.updatedAt,
                    updatedAt: task.updatedAt
                ),
                db: db
            )
        }
    }

    private static func insertDependency(_ dependency: ScheduleDependency, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO schedule_task_dependencies
              (id, project_id, schedule_id, predecessor_task_id, successor_task_id,
               dependency_type, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                dependency.id.uuidString,
                dependency.projectId.uuidString,
                dependency.scheduleId.uuidString,
                dependency.predecessorId.uuidString,
                dependency.successorId.uuidString,
                dependency.type.rawValue,
                SQLiteDateCoding.string(from: dependency.createdAt),
                SQLiteDateCoding.string(from: dependency.updatedAt)
            ]
        )
    }

    // MARK: - Row decoding

    private enum ScheduleRowError: Error {
        case invalidColumn(String)
    }

    private static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let raw: String = row[column], let id = UUID(uuidString: raw) else {
            throw ScheduleRowError.invalidColumn(column)
        }
        return id
    }

    private static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
        (row[column] as String?).flatMap(UUID.init(uuidString:))
    }

    private static func date(_ row: Row, _ column: String) throws -> Date {
        guard let raw: String = row[column], let value = SQLiteDateCoding.date(from: raw) else {
            throw ScheduleRowError.invalidColumn(column)
        }
        return value
    }

    private static func day(_ row: Row, _ column: String) throws -> CalendarDay {
        guard let raw: String = row[column], let value = CalendarDay(isoString: raw) else {
            throw ScheduleRowError.invalidColumn(column)
        }
        return value
    }

    private static func schedule(from row: Row) throws -> ConstructionSchedule {
        ConstructionSchedule(
            id: try uuid(row, "id"),
            projectId: try uuid(row, "project_id"),
            name: row["name"],
            details: row["details"] ?? "",
            createdAt: try date(row, "created_at"),
            updatedAt: try date(row, "updated_at")
        )
    }

    private static func phase(from row: Row) throws -> SchedulePhase {
        SchedulePhase(
            id: try uuid(row, "id"),
            projectId: try uuid(row, "project_id"),
            scheduleId: try uuid(row, "schedule_id"),
            name: row["name"],
            colorHex: row["color"] ?? "#1C7AE6",
            sortOrder: row["sort_order"],
            createdAt: try date(row, "created_at"),
            updatedAt: try date(row, "updated_at")
        )
    }

    private static func task(from row: Row) throws -> ScheduleTask {
        guard let kind = ScheduleTaskKind(rawValue: row["kind"]) else {
            throw ScheduleRowError.invalidColumn("kind")
        }
        guard let status = ScheduleTaskStatus(rawValue: row["status"]) else {
            throw ScheduleRowError.invalidColumn("status")
        }
        return ScheduleTask(
            id: try uuid(row, "id"),
            projectId: try uuid(row, "project_id"),
            scheduleId: try uuid(row, "schedule_id"),
            phaseId: optionalUUID(row, "phase_id"),
            kind: kind,
            title: row["title"],
            details: row["details"] ?? "",
            startDay: try day(row, "start_date"),
            finishDay: try day(row, "finish_date"),
            progress: row["progress"],
            status: status,
            responsibleName: row["responsible_name"],
            responsibleContactId: optionalUUID(row, "responsible_contact_id"),
            notes: row["notes"] ?? "",
            sortOrder: row["sort_order"],
            createdAt: try date(row, "created_at"),
            updatedAt: try date(row, "updated_at")
        )
    }

    private static func dependency(from row: Row) throws -> ScheduleDependency {
        guard let type = ScheduleDependencyType(rawValue: row["dependency_type"]) else {
            throw ScheduleRowError.invalidColumn("dependency_type")
        }
        return ScheduleDependency(
            id: try uuid(row, "id"),
            projectId: try uuid(row, "project_id"),
            scheduleId: try uuid(row, "schedule_id"),
            predecessorId: try uuid(row, "predecessor_task_id"),
            successorId: try uuid(row, "successor_task_id"),
            type: type,
            createdAt: try date(row, "created_at"),
            updatedAt: try date(row, "updated_at")
        )
    }
}
