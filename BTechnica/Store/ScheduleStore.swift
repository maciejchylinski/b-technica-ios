import Foundation

/// One project's construction schedule, backed by the per-user SQLite database.
/// Local only; schedule cloud sync is not implemented yet.
@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var snapshot: ScheduleSnapshot = .empty
    @Published var errorMessage: String?

    let project: Project
    /// Existing contractor dictionary names offered as responsibility suggestions.
    let contractorNames: [String]
    private let database: AppDatabase?

    static let phasePalette: [String] = [
        "#1C7AE6", "#2E9E5B", "#E08A1E", "#8E5BD6",
        "#D6455D", "#1BA3A3", "#7A8794", "#B8862B"
    ]

    init(userId: UUID, project: Project, contractorNames: [String] = []) {
        self.project = project
        self.contractorNames = contractorNames
        var opened: AppDatabase?
        do {
            let db = try AppDatabase.shared(for: userId)
            try db.ensureProject(project)
            opened = db
        } catch {
            errorMessage = "Schedule could not be opened: \(error.localizedDescription)"
        }
        database = opened
        reload()
    }

    /// Test / preview hook with an explicit database.
    init(database: AppDatabase, project: Project, contractorNames: [String] = []) {
        self.project = project
        self.contractorNames = contractorNames
        self.database = database
        reload()
    }

    func reload() {
        guard let database else { return }
        do {
            snapshot = try database.fetchScheduleSnapshot(projectId: project.id)
        } catch {
            errorMessage = "Schedule could not be loaded: \(error.localizedDescription)"
        }
    }

    // MARK: - Read helpers

    var schedule: ConstructionSchedule? { snapshot.schedule }
    var phases: [SchedulePhase] { snapshot.phases }
    var tasks: [ScheduleTask] { snapshot.tasks }
    var dependencies: [ScheduleDependency] { snapshot.dependencies }

    func task(id: UUID) -> ScheduleTask? {
        snapshot.tasks.first { $0.id == id }
    }

    func phase(id: UUID?) -> SchedulePhase? {
        guard let id else { return nil }
        return snapshot.phases.first { $0.id == id }
    }

    /// Tasks for a phase (`nil` = no phase) in display order.
    func tasks(inPhase phaseId: UUID?) -> [ScheduleTask] {
        snapshot.tasks.filter { $0.phaseId == phaseId }
    }

    var hasUnphasedTasks: Bool {
        snapshot.tasks.contains { $0.phaseId == nil }
    }

    func predecessors(of taskId: UUID) -> [(dependency: ScheduleDependency, task: ScheduleTask)] {
        snapshot.dependencies
            .filter { $0.successorId == taskId }
            .compactMap { dep in task(id: dep.predecessorId).map { (dep, $0) } }
    }

    func successors(of taskId: UUID) -> [(dependency: ScheduleDependency, task: ScheduleTask)] {
        snapshot.dependencies
            .filter { $0.predecessorId == taskId }
            .compactMap { dep in task(id: dep.successorId).map { (dep, $0) } }
    }

    var edges: [ScheduleRules.Edge] {
        snapshot.dependencies.map { .init(predecessor: $0.predecessorId, successor: $0.successorId) }
    }

    /// Predecessors whose finish-to-start rule this task currently breaks.
    func dependencyConflicts(for task: ScheduleTask) -> [ScheduleTask] {
        predecessors(of: task.id)
            .map(\.task)
            .filter { ScheduleRules.violatesFinishToStart(predecessor: $0, successor: task) }
    }

    /// Distinct responsible names already used in this schedule.
    var responsibleNames: [String] {
        Array(Set(snapshot.tasks.compactMap(\.responsibleName)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Names used in this schedule plus the contractor dictionary.
    var responsibleSuggestions: [String] {
        Array(Set(responsibleNames + contractorNames))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Schedule

    @discardableResult
    func createSchedule(name: String, details: String) -> Bool {
        let now = Date()
        let schedule = ConstructionSchedule(
            id: UUID(),
            projectId: project.id,
            name: name,
            details: details,
            createdAt: now,
            updatedAt: now
        )
        return perform { try $0.createSchedule(schedule) }
    }

    @discardableResult
    func updateSchedule(name: String, details: String) -> Bool {
        guard var schedule = snapshot.schedule else { return false }
        schedule.name = name
        schedule.details = details
        schedule.updatedAt = Date()
        return perform { try $0.updateSchedule(schedule) }
    }

    func deleteSchedule() {
        guard let schedule = snapshot.schedule else { return }
        perform { try $0.deleteSchedule(id: schedule.id, projectId: self.project.id) }
    }

    // MARK: - Phases

    func newPhaseDraft() -> SchedulePhase? {
        guard let schedule = snapshot.schedule else { return nil }
        let now = Date()
        let color = Self.phasePalette[snapshot.phases.count % Self.phasePalette.count]
        return SchedulePhase(
            id: UUID(),
            projectId: project.id,
            scheduleId: schedule.id,
            name: "",
            colorHex: color,
            sortOrder: (snapshot.phases.map(\.sortOrder).max() ?? -1) + 1,
            createdAt: now,
            updatedAt: now
        )
    }

    func savePhase(_ phase: SchedulePhase) throws {
        guard let database else { throw ScheduleValidationError.notFound }
        var updated = phase
        updated.updatedAt = Date()
        try database.savePhase(updated)
        reload()
    }

    func deletePhase(id: UUID) {
        perform { try $0.deletePhase(id: id, projectId: self.project.id) }
    }

    func movePhases(from source: IndexSet, to destination: Int) {
        guard let schedule = snapshot.schedule else { return }
        var ordered = snapshot.phases
        ordered.move(fromOffsets: source, toOffset: destination)
        perform {
            try $0.reorderPhases(ordered.map(\.id), scheduleId: schedule.id, projectId: self.project.id, at: Date())
        }
    }

    // MARK: - Tasks

    func newTaskDraft(phaseId: UUID?, kind: ScheduleTaskKind) -> ScheduleTask? {
        guard let schedule = snapshot.schedule else { return nil }
        let now = Date()
        let start = CalendarDay.today()
        let siblings = tasks(inPhase: phaseId)
        return ScheduleTask(
            id: UUID(),
            projectId: project.id,
            scheduleId: schedule.id,
            phaseId: phaseId,
            kind: kind,
            title: "",
            details: "",
            startDay: start,
            finishDay: kind == .milestone ? start : start.adding(days: 4),
            progress: 0,
            status: .planned,
            responsibleName: nil,
            responsibleContactId: nil,
            notes: "",
            sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Saves a task from the editor. Moving to another phase appends it there.
    func saveTask(_ task: ScheduleTask, predecessorIds: [UUID]?) throws {
        guard let database else { throw ScheduleValidationError.notFound }
        var updated = task
        if let existing = self.task(id: task.id), existing.phaseId != task.phaseId {
            updated.sortOrder = (tasks(inPhase: task.phaseId).map(\.sortOrder).max() ?? -1) + 1
        }
        updated.updatedAt = Date()
        try database.saveTask(updated, predecessorIds: predecessorIds)
        reload()
    }

    func setProgress(_ progress: Int, taskId: UUID) {
        guard let task = task(id: taskId) else { return }
        quickSave(ScheduleRules.applyingProgress(progress, to: task))
    }

    func setStatus(_ status: ScheduleTaskStatus, taskId: UUID) {
        guard let task = task(id: taskId) else { return }
        quickSave(ScheduleRules.applyingStatus(status, to: task))
    }

    func deleteTask(id: UUID) {
        perform { try $0.deleteTask(id: id, projectId: self.project.id) }
    }

    /// Reorders within one phase group (indices refer to `tasks(inPhase:)`).
    func moveTasks(inPhase phaseId: UUID?, from source: IndexSet, to destination: Int) {
        guard let schedule = snapshot.schedule else { return }
        var ordered = tasks(inPhase: phaseId)
        ordered.move(fromOffsets: source, toOffset: destination)
        perform {
            try $0.reorderTasks(ordered.map(\.id), scheduleId: schedule.id, projectId: self.project.id, at: Date())
        }
    }

    // MARK: - Dependencies

    func addDependency(predecessorId: UUID, successorId: UUID) throws {
        guard let database, let schedule = snapshot.schedule else { throw ScheduleValidationError.notFound }
        let now = Date()
        try database.addDependency(
            ScheduleDependency(
                id: UUID(),
                projectId: project.id,
                scheduleId: schedule.id,
                predecessorId: predecessorId,
                successorId: successorId,
                type: .finishToStart,
                createdAt: now,
                updatedAt: now
            )
        )
        reload()
    }

    func removeDependency(id: UUID) {
        perform { try $0.deleteDependency(id: id, projectId: self.project.id) }
    }

    // MARK: - Private

    private func quickSave(_ task: ScheduleTask) {
        var updated = task
        updated.updatedAt = Date()
        perform { try $0.saveTask(updated) }
    }

    @discardableResult
    private func perform(_ work: (AppDatabase) throws -> Void) -> Bool {
        guard let database else {
            errorMessage = "Schedule storage is unavailable."
            return false
        }
        do {
            try work(database)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return false
        }
    }
}
