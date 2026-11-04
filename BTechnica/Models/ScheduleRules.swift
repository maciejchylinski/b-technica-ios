import Foundation

enum ScheduleValidationError: LocalizedError, Equatable {
    case emptyScheduleName
    case emptyPhaseName
    case emptyTaskTitle
    case finishBeforeStart
    case selfDependency
    case duplicateDependency
    case circularDependency
    case taskNotInSchedule
    case phaseNotInSchedule
    case scheduleAlreadyExists
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyScheduleName: return "Enter a schedule name."
        case .emptyPhaseName: return "Enter a phase name."
        case .emptyTaskTitle: return "Enter a task title."
        case .finishBeforeStart: return "The finish date can’t be before the start date."
        case .selfDependency: return "A task can’t depend on itself."
        case .duplicateDependency: return "This dependency already exists."
        case .circularDependency:
            return "This dependency would create a loop. A task can’t (directly or indirectly) wait for itself."
        case .taskNotInSchedule: return "That task belongs to a different schedule."
        case .phaseNotInSchedule: return "That phase belongs to a different schedule."
        case .scheduleAlreadyExists: return "This project already has a schedule."
        case .notFound: return "The item no longer exists."
        }
    }
}

/// Pure scheduling rules shared by persistence, store, and UI.
enum ScheduleRules {
    static let maxDurationDays = 3650

    /// Trims text, enforces date order, milestone shape, progress bounds and
    /// "completed ⇒ 100 %". Throws instead of silently swapping dates.
    static func normalized(_ task: ScheduleTask) throws -> ScheduleTask {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.title.isEmpty else { throw ScheduleValidationError.emptyTaskTitle }
        t.details = t.details.trimmingCharacters(in: .whitespacesAndNewlines)
        t.notes = t.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let responsible = t.responsibleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t.responsibleName = responsible.isEmpty ? nil : responsible

        if t.isMilestone {
            t.finishDay = t.startDay
        } else if t.finishDay < t.startDay {
            throw ScheduleValidationError.finishBeforeStart
        }
        t.progress = min(100, max(0, t.progress))
        if t.status == .completed {
            t.progress = 100
        }
        return t
    }

    /// Quick progress update from list / detail: keeps status in step with progress.
    static func applyingProgress(_ progress: Int, to task: ScheduleTask) -> ScheduleTask {
        var t = task
        t.progress = min(100, max(0, progress))
        if t.progress == 100 {
            t.status = .completed
        } else if t.status == .completed {
            t.status = .inProgress
        } else if t.progress > 0, t.status == .planned {
            t.status = .inProgress
        }
        return t
    }

    /// Quick status update: completing sets 100 %, reopening a completed task keeps its
    /// progress below 100 %.
    static func applyingStatus(_ status: ScheduleTaskStatus, to task: ScheduleTask) -> ScheduleTask {
        var t = task
        t.status = status
        if status == .completed {
            t.progress = 100
        } else if t.progress == 100 {
            t.progress = 90
        }
        return t
    }

    // MARK: - Finish-to-start

    /// First day `successor` may start: the day after a task finishes, or the
    /// milestone day itself.
    static func earliestStart(after predecessor: ScheduleTask) -> CalendarDay {
        predecessor.isMilestone ? predecessor.finishDay : predecessor.finishDay.adding(days: 1)
    }

    /// True when `successor` starts before `predecessor` allows (dates conflict).
    static func violatesFinishToStart(predecessor: ScheduleTask, successor: ScheduleTask) -> Bool {
        successor.startDay < earliestStart(after: predecessor)
    }

    // MARK: - Cycles

    /// Edge `predecessor → successor`.
    struct Edge: Hashable {
        var predecessor: UUID
        var successor: UUID
    }

    /// Would adding `candidate` to `edges` create a cycle (incl. a self-loop)?
    static func wouldCreateCycle(adding candidate: Edge, to edges: [Edge]) -> Bool {
        if candidate.predecessor == candidate.successor { return true }
        var outgoing: [UUID: [UUID]] = [:]
        for edge in edges {
            outgoing[edge.predecessor, default: []].append(edge.successor)
        }
        // Cycle iff predecessor is reachable from successor.
        var stack = [candidate.successor]
        var visited: Set<UUID> = []
        while let node = stack.popLast() {
            if node == candidate.predecessor { return true }
            guard visited.insert(node).inserted else { continue }
            stack.append(contentsOf: outgoing[node] ?? [])
        }
        return false
    }

    /// Validates replacing all predecessors of `taskId` with `predecessorIds`.
    /// `existing` is every dependency edge in the schedule.
    static func validatePredecessors(
        _ predecessorIds: [UUID],
        of taskId: UUID,
        existing: [Edge]
    ) throws {
        var edges = existing.filter { $0.successor != taskId }
        var seen: Set<UUID> = []
        for predecessorId in predecessorIds {
            guard predecessorId != taskId else { throw ScheduleValidationError.selfDependency }
            guard seen.insert(predecessorId).inserted else {
                throw ScheduleValidationError.duplicateDependency
            }
            let edge = Edge(predecessor: predecessorId, successor: taskId)
            if wouldCreateCycle(adding: edge, to: edges) {
                throw ScheduleValidationError.circularDependency
            }
            edges.append(edge)
        }
    }

    /// Task ids that cannot become predecessors of `taskId` without a cycle
    /// (the task itself and everything downstream of it).
    static func blockedPredecessors(for taskId: UUID, edges: [Edge]) -> Set<UUID> {
        var outgoing: [UUID: [UUID]] = [:]
        for edge in edges {
            outgoing[edge.predecessor, default: []].append(edge.successor)
        }
        var blocked: Set<UUID> = []
        var stack = [taskId]
        while let node = stack.popLast() {
            guard blocked.insert(node).inserted else { continue }
            stack.append(contentsOf: outgoing[node] ?? [])
        }
        return blocked
    }
}
