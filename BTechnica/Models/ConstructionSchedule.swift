import Foundation

// Construction schedule domain models (one schedule per project).
//
// All ids are client-generated UUIDs so rows can later be pushed to the matching
// Supabase tables (`schedules`, `schedule_phases`, `schedule_tasks`,
// `schedule_task_dependencies`) without remapping. Schedule cloud sync is not
// implemented yet; these rows stay local.

struct ConstructionSchedule: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    var projectId: UUID
    var name: String
    var details: String
    var createdAt: Date
    var updatedAt: Date
}

/// A user-named group of tasks (e.g. "Foundations"). Names are free text.
struct SchedulePhase: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    var projectId: UUID
    var scheduleId: UUID
    var name: String
    /// `#RRGGBB`
    var colorHex: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

enum ScheduleTaskKind: String, Codable, CaseIterable, Identifiable {
    case task
    case milestone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task: return "Task"
        case .milestone: return "Milestone"
        }
    }
}

enum ScheduleTaskStatus: String, Codable, CaseIterable, Identifiable {
    case planned
    case inProgress
    case completed
    case delayed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .planned: return "Planned"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .delayed: return "Delayed"
        }
    }

    var systemImage: String {
        switch self {
        case .planned: return "calendar"
        case .inProgress: return "hammer"
        case .completed: return "checkmark.circle.fill"
        case .delayed: return "exclamationmark.triangle.fill"
        }
    }
}

struct ScheduleTask: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    var projectId: UUID
    var scheduleId: UUID
    /// `nil` = task is not grouped under a phase.
    var phaseId: UUID?
    var kind: ScheduleTaskKind
    var title: String
    var details: String
    var startDay: CalendarDay
    /// Inclusive last working day. Equals `startDay` for milestones.
    var finishDay: CalendarDay
    /// 0…100
    var progress: Int
    var status: ScheduleTaskStatus
    /// Free-text person or contractor responsible.
    var responsibleName: String?
    /// Reserved for the Project Contacts module (`project_contacts.id`). Not enforced
    /// by a foreign key and not edited by the UI yet; preserved on save.
    var responsibleContactId: UUID?
    var notes: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    var isMilestone: Bool { kind == .milestone }

    /// Inclusive calendar days; 0 for milestones.
    var durationDays: Int {
        isMilestone ? 0 : startDay.days(to: finishDay) + 1
    }

    /// Not completed and the finish day has passed.
    func isOverdue(today: CalendarDay) -> Bool {
        status != .completed && finishDay < today
    }

    /// Explicitly delayed, or overdue.
    func isBehind(today: CalendarDay) -> Bool {
        status == .delayed || isOverdue(today: today)
    }
}

enum ScheduleDependencyType: String, Codable, CaseIterable {
    case finishToStart = "finish_to_start"
}

/// `successor` may not start before `predecessor` finishes.
struct ScheduleDependency: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    var projectId: UUID
    var scheduleId: UUID
    var predecessorId: UUID
    var successorId: UUID
    var type: ScheduleDependencyType
    var createdAt: Date
    var updatedAt: Date
}

/// Everything needed to render one project's schedule.
struct ScheduleSnapshot: Equatable {
    var schedule: ConstructionSchedule?
    var phases: [SchedulePhase]
    var tasks: [ScheduleTask]
    var dependencies: [ScheduleDependency]

    static let empty = ScheduleSnapshot(schedule: nil, phases: [], tasks: [], dependencies: [])
}
