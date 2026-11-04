import Foundation

/// Read-only rollups for the overview and upcoming-work screens.
struct ScheduleSummary: Equatable {
    var totalTasks: Int
    var completed: Int
    var inProgress: Int
    var planned: Int
    /// Explicitly delayed or overdue (not completed).
    var behind: Int
    var overdue: Int
    var milestonesTotal: Int
    var milestonesCompleted: Int
    /// Duration-weighted physical progress, 0…100 (milestones count as one day).
    var overallProgress: Int
    var startDay: CalendarDay?
    var finishDay: CalendarDay?

    init(tasks: [ScheduleTask], today: CalendarDay) {
        let work = tasks.filter { !$0.isMilestone }
        let milestones = tasks.filter(\.isMilestone)
        totalTasks = work.count
        completed = work.filter { $0.status == .completed }.count
        inProgress = work.filter { $0.status == .inProgress }.count
        planned = work.filter { $0.status == .planned }.count
        behind = tasks.filter { $0.isBehind(today: today) }.count
        overdue = tasks.filter { $0.isOverdue(today: today) }.count
        milestonesTotal = milestones.count
        milestonesCompleted = milestones.filter { $0.status == .completed }.count

        let weights = tasks.map { max(1, $0.durationDays) }
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            let done = zip(tasks, weights).reduce(0) { $0 + $1.0.progress * $1.1 }
            overallProgress = Int((Double(done) / Double(totalWeight)).rounded())
        } else {
            overallProgress = 0
        }
        startDay = tasks.map(\.startDay).min()
        finishDay = tasks.map(\.finishDay).max()
    }
}

/// Field-oriented "what's next" buckets. A task appears in at most one bucket,
/// in priority order: overdue → starting soon → due soon.
struct ScheduleUpcoming: Equatable {
    var overdue: [ScheduleTask]
    var startingSoon: [ScheduleTask]
    var dueSoon: [ScheduleTask]

    init(tasks: [ScheduleTask], today: CalendarDay, horizonDays: Int) {
        let horizon = today.adding(days: horizonDays)
        var overdue: [ScheduleTask] = []
        var starting: [ScheduleTask] = []
        var due: [ScheduleTask] = []
        for task in tasks where task.status != .completed {
            if task.finishDay < today {
                overdue.append(task)
            } else if task.status != .inProgress, task.startDay >= today, task.startDay <= horizon {
                starting.append(task)
            } else if task.finishDay <= horizon {
                due.append(task)
            }
        }
        self.overdue = overdue.sorted { ($0.finishDay, $0.title) < ($1.finishDay, $1.title) }
        self.startingSoon = starting.sorted { ($0.startDay, $0.title) < ($1.startDay, $1.title) }
        self.dueSoon = due.sorted { ($0.finishDay, $0.title) < ($1.finishDay, $1.title) }
    }

    var isEmpty: Bool { overdue.isEmpty && startingSoon.isEmpty && dueSoon.isEmpty }
}

enum ScheduleAnalytics {
    /// Next open milestones (overdue ones first, then by date).
    static func nearestMilestones(_ tasks: [ScheduleTask], today: CalendarDay, limit: Int = 5) -> [ScheduleTask] {
        let open = tasks.filter { $0.isMilestone && $0.status != .completed }
        return Array(open.sorted { ($0.startDay, $0.title) < ($1.startDay, $1.title) }.prefix(limit))
    }

    /// Duration-weighted progress for a group of tasks, 0…100.
    static func progress(of tasks: [ScheduleTask]) -> Int {
        ScheduleSummary(tasks: tasks, today: .today()).overallProgress
    }
}
