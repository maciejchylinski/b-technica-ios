import SwiftUI

/// Project schedule dashboard: counts, overall progress, nearest milestones,
/// per-phase progress and shortcuts. Two columns on iPad.
struct ScheduleOverviewView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let onSelectFilter: (ScheduleTaskFilter) -> Void
    let onOpenSection: (ScheduleSection) -> Void
    let onAddTask: () -> Void
    let onAddPhase: () -> Void

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        let today = CalendarDay.today()
        let summary = ScheduleSummary(tasks: store.tasks, today: today)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard(summary: summary, today: today)
                tiles(summary: summary)
                if isRegular {
                    HStack(alignment: .top, spacing: 16) {
                        milestonesCard(today: today)
                        phasesCard(today: today)
                    }
                } else {
                    milestonesCard(today: today)
                    phasesCard(today: today)
                }
                shortcutsCard
            }
            .padding(16)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    private func headerCard(summary: ScheduleSummary, today: CalendarDay) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.project.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let start = summary.startDay, let finish = summary.finishDay {
                    Text("\(ScheduleDateFormat.medium(start)) – \(ScheduleDateFormat.medium(finish))")
                        .font(.headline)
                    let total = start.days(to: finish) + 1
                    let elapsed = min(max(0, start.days(to: today) + 1), total)
                    Text("Day \(elapsed) of \(total) · \(ScheduleDateFormat.relative(finish, today: today)) to finish")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No dated activities yet")
                        .font(.headline)
                }
                HStack(spacing: 10) {
                    ScheduleProgressBar(progress: summary.overallProgress, height: 10)
                    Text("\(summary.overallProgress)%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                Text("Physical progress, weighted by task duration.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let details = store.schedule?.details, !details.isEmpty {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tiles(summary: ScheduleSummary) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: isRegular ? 4 : 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            tile("Total tasks", value: summary.totalTasks, systemImage: "list.bullet", color: Theme.blue) {
                onSelectFilter(.all)
            }
            tile("Completed", value: summary.completed, systemImage: "checkmark.circle.fill", color: .green) {
                onSelectFilter(.completed)
            }
            tile("In progress", value: summary.inProgress, systemImage: "hammer.fill", color: Theme.blue) {
                onSelectFilter(.inProgress)
            }
            tile("Delayed / overdue", value: summary.behind, systemImage: "exclamationmark.triangle.fill",
                 color: summary.behind > 0 ? .red : .secondary) {
                onSelectFilter(.behind)
            }
        }
    }

    private func tile(_ title: String, value: Int, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text("\(value)")
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows these tasks")
    }

    private func milestonesCard(today: CalendarDay) -> some View {
        let milestones = ScheduleAnalytics.nearestMilestones(store.tasks, today: today)
        return card(title: "Nearest milestones") {
            if milestones.isEmpty {
                Text(store.tasks.contains(where: \.isMilestone) ? "All milestones are completed." : "No milestones yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(milestones) { milestone in
                        NavigationLink(value: ScheduleTaskRoute(id: milestone.id)) {
                            HStack(spacing: 10) {
                                MilestoneGlyph(
                                    color: milestone.isBehind(today: today)
                                        ? ScheduleStyle.behind
                                        : ScheduleStyle.color(hex: store.phase(id: milestone.phaseId)?.colorHex ?? GanttLayout.unphasedColorHex),
                                    size: 14
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(milestone.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(ScheduleDateFormat.weekday(milestone.startDay)) · \(ScheduleDateFormat.relative(milestone.startDay, today: today))")
                                        .font(.caption)
                                        .foregroundStyle(milestone.isOverdue(today: today) ? ScheduleStyle.behind : .secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if milestone.id != milestones.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func phasesCard(today: CalendarDay) -> some View {
        card(title: "Phases") {
            if store.phases.isEmpty {
                Text("No phases yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.phases) { phase in
                        let tasks = store.tasks(inPhase: phase.id)
                        let behind = tasks.filter { $0.isBehind(today: today) }.count
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(ScheduleStyle.color(hex: phase.colorHex)).frame(width: 9, height: 9)
                                Text(phase.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer()
                                if behind > 0 {
                                    Label("\(behind)", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(ScheduleStyle.behind)
                                }
                                Text("\(ScheduleAnalytics.progress(of: tasks))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ScheduleProgressBar(progress: ScheduleAnalytics.progress(of: tasks),
                                                tint: ScheduleStyle.color(hex: phase.colorHex))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var shortcutsCard: some View {
        card(title: "Shortcuts") {
            VStack(spacing: 0) {
                shortcut("Add task", systemImage: "plus.rectangle", action: onAddTask)
                Divider()
                shortcut("Add phase", systemImage: "folder.badge.plus", action: onAddPhase)
                Divider()
                shortcut("Upcoming work", systemImage: "calendar.badge.clock") { onOpenSection(.upcoming) }
                Divider()
                shortcut("Open Gantt chart", systemImage: "chart.bar.xaxis") { onOpenSection(.gantt) }
            }
        }
    }

    private func shortcut(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.blue)
                    .frame(width: 28)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
