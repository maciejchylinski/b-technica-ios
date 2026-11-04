import SwiftUI

/// "What's next on site": overdue work, activities starting soon, and activities
/// due soon. A list on iPhone; three side-by-side columns on iPad.
struct ScheduleUpcomingView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("schedule.upcoming.horizon") private var horizonDays = 14

    private static let horizons = [7, 14, 30]

    var body: some View {
        let today = CalendarDay.today()
        let upcoming = ScheduleUpcoming(tasks: store.tasks, today: today, horizonDays: horizonDays)
        let buckets: [(title: String, systemImage: String, color: Color, tasks: [ScheduleTask], empty: String)] = [
            ("Overdue", "exclamationmark.triangle.fill", ScheduleStyle.behind, upcoming.overdue, "Nothing overdue."),
            ("Starting soon", "play.circle", Theme.blue, upcoming.startingSoon, "Nothing starts in the next \(horizonDays) days."),
            ("Due soon", "flag.checkered", .orange, upcoming.dueSoon, "Nothing is due in the next \(horizonDays) days.")
        ]

        VStack(spacing: 0) {
            Picker("Look ahead", selection: $horizonDays) {
                ForEach(Self.horizons, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if horizontalSizeClass == .regular {
                ScrollView {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(buckets, id: \.title) { bucket in
                            column(bucket.title, systemImage: bucket.systemImage, color: bucket.color,
                                   tasks: bucket.tasks, empty: bucket.empty, today: today)
                        }
                    }
                    .padding(16)
                }
            } else {
                List {
                    ForEach(buckets, id: \.title) { bucket in
                        Section {
                            if bucket.tasks.isEmpty {
                                Text(bucket.empty)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(bucket.tasks) { task in
                                link(task, today: today)
                            }
                        } header: {
                            Label("\(bucket.title) (\(bucket.tasks.count))", systemImage: bucket.systemImage)
                                .foregroundStyle(bucket.color)
                                .font(.subheadline.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Theme.background)
    }

    private func column(_ title: String, systemImage: String, color: Color, tasks: [ScheduleTask], empty: String, today: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(title) (\(tasks.count))", systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            if tasks.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(tasks) { task in
                link(task, today: today)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func link(_ task: ScheduleTask, today: CalendarDay) -> some View {
        NavigationLink(value: ScheduleTaskRoute(id: task.id)) {
            UpcomingRow(task: task, phase: store.phase(id: task.phaseId), today: today)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if task.status != .completed {
                Button {
                    store.setStatus(.completed, taskId: task.id)
                } label: {
                    Label("Mark completed", systemImage: "checkmark")
                }
            }
            if task.status == .planned || task.status == .delayed {
                Button {
                    store.setStatus(.inProgress, taskId: task.id)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
            if task.status != .delayed {
                Button {
                    store.setStatus(.delayed, taskId: task.id)
                } label: {
                    Label("Mark delayed", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }
}

private struct UpcomingRow: View {
    let task: ScheduleTask
    let phase: SchedulePhase?
    let today: CalendarDay

    var body: some View {
        let keyDay = task.isOverdue(today: today) || task.status == .inProgress ? task.finishDay : task.startDay
        let isStart = keyDay == task.startDay && !task.isOverdue(today: today) && task.status != .inProgress
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if task.isMilestone {
                        MilestoneGlyph(color: ScheduleStyle.color(hex: phase?.colorHex ?? GanttLayout.unphasedColorHex), size: 12)
                    }
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Text("\(task.isMilestone ? "On" : (isStart ? "Starts" : "Due")) \(ScheduleDateFormat.weekday(keyDay)) · \(ScheduleDateFormat.relative(keyDay, today: today))")
                    .font(.caption)
                    .foregroundStyle(task.isOverdue(today: today) ? ScheduleStyle.behind : .secondary)
                HStack(spacing: 6) {
                    if let phase { Text(phase.name) }
                    if let name = task.responsibleName {
                        if phase != nil { Text("·") }
                        Label(name, systemImage: "person")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                ScheduleStatusBadge(task: task, today: today)
                if !task.isMilestone {
                    Text("\(task.progress)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
