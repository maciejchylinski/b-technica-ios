import Foundation

/// Row model for the Gantt chart, rebuilt when schedule data or collapsed phases change
/// (not while scrolling). Rendering only touches rows inside the viewport.
struct GanttLayout {
    /// Grouping key: phase id, or `nil` for tasks without a phase.
    typealias GroupKey = UUID?

    struct PhaseRow {
        var key: GroupKey
        var name: String
        var colorHex: String
        /// Inclusive day range covered by the phase's tasks.
        var startOrdinal: Int?
        var finishOrdinal: Int?
        var progress: Int
        var taskCount: Int
        var behindCount: Int
        var isCollapsed: Bool
    }

    struct TaskRow {
        var task: ScheduleTask
        var colorHex: String
        var isBehind: Bool
        /// Starts before one of its predecessors allows.
        var hasConflict: Bool
    }

    enum Row {
        case phase(PhaseRow)
        case task(TaskRow)
    }

    /// Finish-to-start arrow between two visible rows.
    struct Link {
        var fromRow: Int
        var toRow: Int
        /// Day ordinal where the arrow leaves (exclusive end of predecessor bar).
        var fromOrdinal: Int
        var fromIsMilestone: Bool
        var toOrdinal: Int
        var toIsMilestone: Bool
        var isConflict: Bool
    }

    static let unphasedColorHex = "#7A8794"

    private(set) var rows: [Row] = []
    private(set) var taskRowIndex: [UUID: Int] = [:]
    private(set) var links: [Link] = []
    /// First day drawn on the timeline.
    private(set) var originDay: CalendarDay
    private(set) var dayCount: Int
    let todayOrdinal: Int
    private(set) var behindCount = 0

    init(snapshot: ScheduleSnapshot, collapsed: Set<GroupKey>, today: CalendarDay) {
        todayOrdinal = today.ordinal

        let tasks = snapshot.tasks
        let minStart = (tasks.map(\.startDay) + [today]).min()!
        let maxFinish = (tasks.map(\.finishDay) + [today]).max()!
        originDay = minStart.adding(days: -7).startOfMonth
        let end = maxFinish.adding(days: 45).startOfNextMonth
        dayCount = max(1, originDay.days(to: end))

        var byPhase: [UUID?: [ScheduleTask]] = [:]
        for task in tasks {
            byPhase[task.phaseId, default: []].append(task)
        }
        let predecessorsBySuccessor = Dictionary(grouping: snapshot.dependencies, by: \.successorId)
        let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        var groups: [(key: GroupKey, name: String, color: String)] = snapshot.phases.map {
            ($0.id, $0.name, $0.colorHex)
        }
        if byPhase[GroupKey.none] != nil {
            groups.append((nil, "No phase", Self.unphasedColorHex))
        }

        for group in groups {
            let groupTasks = byPhase[group.key] ?? []
            let isCollapsed = collapsed.contains(group.key)
            var behind = 0
            var taskRows: [TaskRow] = []
            taskRows.reserveCapacity(groupTasks.count)
            for task in groupTasks {
                let isBehind = task.isBehind(today: today)
                if isBehind { behind += 1 }
                let conflict = (predecessorsBySuccessor[task.id] ?? []).contains { dep in
                    guard let pred = taskById[dep.predecessorId] else { return false }
                    return ScheduleRules.violatesFinishToStart(predecessor: pred, successor: task)
                }
                taskRows.append(TaskRow(task: task, colorHex: group.color, isBehind: isBehind, hasConflict: conflict))
            }
            behindCount += behind
            rows.append(.phase(PhaseRow(
                key: group.key,
                name: group.name,
                colorHex: group.color,
                startOrdinal: groupTasks.map(\.startDay.ordinal).min(),
                finishOrdinal: groupTasks.map(\.finishDay.ordinal).max(),
                progress: ScheduleSummary(tasks: groupTasks, today: today).overallProgress,
                taskCount: groupTasks.count,
                behindCount: behind,
                isCollapsed: isCollapsed
            )))
            guard !isCollapsed else { continue }
            for row in taskRows {
                taskRowIndex[row.task.id] = rows.count
                rows.append(.task(row))
            }
        }

        for dep in snapshot.dependencies {
            guard let fromRow = taskRowIndex[dep.predecessorId],
                  let toRow = taskRowIndex[dep.successorId],
                  let pred = taskById[dep.predecessorId],
                  let succ = taskById[dep.successorId]
            else { continue }
            links.append(Link(
                fromRow: fromRow,
                toRow: toRow,
                fromOrdinal: pred.isMilestone ? pred.finishDay.ordinal : pred.finishDay.ordinal + 1,
                fromIsMilestone: pred.isMilestone,
                toOrdinal: succ.startDay.ordinal,
                toIsMilestone: succ.isMilestone,
                isConflict: ScheduleRules.violatesFinishToStart(predecessor: pred, successor: succ)
            ))
        }
    }

    /// Day index on the timeline (0 = `originDay`).
    func dayIndex(_ ordinal: Int) -> Int { ordinal - originDay.ordinal }

    var firstTaskStartOrdinal: Int? {
        rows.compactMap { if case .phase(let p) = $0 { return p.startOrdinal } else { return nil } }.min()
    }

    var lastTaskFinishOrdinal: Int? {
        rows.compactMap { if case .phase(let p) = $0 { return p.finishOrdinal } else { return nil } }.max()
    }
}
