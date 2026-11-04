import SwiftUI

enum ScheduleTaskFilter: String, CaseIterable, Identifiable {
    case all, open, inProgress, behind, completed, milestones

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .open: return "Not done"
        case .inProgress: return "In progress"
        case .behind: return "Behind"
        case .completed: return "Completed"
        case .milestones: return "Milestones"
        }
    }

    func matches(_ task: ScheduleTask, today: CalendarDay) -> Bool {
        switch self {
        case .all: return true
        case .open: return task.status != .completed
        case .inProgress: return task.status == .inProgress
        case .behind: return task.isBehind(today: today)
        case .completed: return task.status == .completed
        case .milestones: return task.isMilestone
        }
    }
}

/// Field task list: grouped by phase, searchable, filterable, with swipe and
/// long-press quick updates. Reorder mode moves tasks within a phase.
struct ScheduleTaskListView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var filter: ScheduleTaskFilter
    let onAddTask: (UUID?) -> Void
    let onEditTask: (UUID) -> Void
    let onAddPhase: () -> Void
    let onEditPhase: (UUID) -> Void

    @State private var searchText = ""
    @State private var responsibleFilter: String?
    @State private var isReordering = false
    @State private var pendingDelete: ScheduleTask?

    private var today: CalendarDay { .today() }

    private var isFiltering: Bool {
        filter != .all || responsibleFilter != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private struct PhaseGroup: Identifiable {
        var id: String
        var phaseId: UUID?
        var name: String
        var colorHex: String
        var allTasks: [ScheduleTask]
        var tasks: [ScheduleTask]
    }

    private var groups: [PhaseGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let day = today
        func visible(_ tasks: [ScheduleTask]) -> [ScheduleTask] {
            tasks.filter { task in
                guard filter.matches(task, today: day) else { return false }
                if let responsibleFilter, task.responsibleName != responsibleFilter { return false }
                guard !query.isEmpty else { return true }
                return [task.title, task.details, task.notes, task.responsibleName ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        var result = store.phases.map { phase in
            let all = store.tasks(inPhase: phase.id)
            return PhaseGroup(id: phase.id.uuidString, phaseId: phase.id, name: phase.name,
                         colorHex: phase.colorHex, allTasks: all, tasks: visible(all))
        }
        if store.hasUnphasedTasks {
            let all = store.tasks(inPhase: nil)
            result.append(PhaseGroup(id: "none", phaseId: nil, name: "No phase",
                                colorHex: GanttLayout.unphasedColorHex, allTasks: all, tasks: visible(all)))
        }
        return isFiltering ? result.filter { !$0.tasks.isEmpty } : result
    }

    var body: some View {
        let groups = self.groups
        List {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if store.phases.isEmpty && store.tasks.isEmpty {
                emptySchedule
            } else if groups.isEmpty {
                Section {
                    ContentUnavailableView.search(text: searchText.isEmpty ? filter.label : searchText)
                }
            }

            ForEach(groups) { group in
                Section {
                    if group.tasks.isEmpty {
                        Button {
                            onAddTask(group.phaseId)
                        } label: {
                            Label("Add task to this phase", systemImage: "plus")
                                .font(.subheadline)
                        }
                    }
                    ForEach(group.tasks) { task in
                        NavigationLink(value: ScheduleTaskRoute(id: task.id)) {
                            ScheduleTaskRow(
                                task: task,
                                phaseColor: ScheduleStyle.color(hex: group.colorHex),
                                today: today,
                                isWide: horizontalSizeClass == .regular,
                                hasConflict: !store.dependencyConflicts(for: task).isEmpty
                            )
                        }
                        .accessibilityIdentifier("scheduleTaskRow")
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            leadingSwipe(task)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = task
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                onEditTask(task.id)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Theme.blue)
                        }
                        .contextMenu { contextMenu(task) }
                    }
                    .onMove(perform: isReordering ? moveHandler(phaseId: group.phaseId) : nil)
                } header: {
                    phaseHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search tasks, people, notes")
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete task", role: .destructive) {
                if let pendingDelete { store.deleteTask(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("Its dependencies are removed too. This can’t be undone.")
        }
    }

    // MARK: - Pieces

    private func moveHandler(phaseId: UUID?) -> (IndexSet, Int) -> Void {
        { source, destination in
            store.moveTasks(inPhase: phaseId, from: source, to: destination)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScheduleTaskFilter.allCases) { value in
                    chip(value.label, isOn: filter == value) {
                        filter = value
                        if value != .all { isReordering = false }
                    }
                }
                Menu {
                    Button("Anyone") { responsibleFilter = nil }
                    ForEach(store.responsibleNames, id: \.self) { name in
                        Button(name) {
                            responsibleFilter = name
                            isReordering = false
                        }
                    }
                } label: {
                    chipLabel(responsibleFilter ?? "Responsible", systemImage: "person", isOn: responsibleFilter != nil)
                }
                .disabled(store.responsibleNames.isEmpty)

                if !isFiltering, !store.tasks.isEmpty {
                    chip(isReordering ? "Done" : "Reorder", isOn: isReordering, systemImage: "arrow.up.arrow.down") {
                        isReordering.toggle()
                    }
                    .accessibilityIdentifier("scheduleReorderButton")
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ title: String, isOn: Bool, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, systemImage: String? = nil, isOn: Bool) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.subheadline.weight(isOn ? .semibold : .regular))
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(isOn ? Theme.blue : Theme.surface, in: Capsule())
        .contentShape(Capsule())
    }

    private func phaseHeader(_ group: PhaseGroup) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ScheduleStyle.color(hex: group.colorHex))
                .frame(width: 10, height: 10)
            Text(group.name)
                .lineLimit(1)
            Text("\(group.allTasks.count)")
                .foregroundStyle(.secondary)
            Spacer()
            if !group.allTasks.isEmpty {
                Text("\(ScheduleAnalytics.progress(of: group.allTasks))%")
                    .foregroundStyle(.secondary)
            }
            if let phaseId = group.phaseId {
                Menu {
                    Button {
                        onAddTask(phaseId)
                    } label: {
                        Label("Add task", systemImage: "plus")
                    }
                    Button {
                        onEditPhase(phaseId)
                    } label: {
                        Label("Edit phase", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: 36, height: 30)
                }
                .accessibilityLabel("Phase actions for \(group.name)")
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }

    private var emptySchedule: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start planning")
                    .font(.headline)
                Text("Group work into phases you name yourself (for example by floor, trade or zone), then add tasks with dates and who is responsible.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add phase", action: onAddPhase)
                        .buttonStyle(.borderedProminent)
                    Button("Add task") { onAddTask(nil) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func leadingSwipe(_ task: ScheduleTask) -> some View {
        if task.status != .completed {
            Button {
                store.setStatus(.completed, taskId: task.id)
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(.green)
        }
        if task.status == .planned || task.status == .delayed {
            Button {
                store.setStatus(.inProgress, taskId: task.id)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(Theme.blue)
        }
    }

    @ViewBuilder
    private func contextMenu(_ task: ScheduleTask) -> some View {
        if !task.isMilestone {
            Menu {
                ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                    Button {
                        store.setProgress(value, taskId: task.id)
                    } label: {
                        if task.progress == value {
                            Label("\(value)%", systemImage: "checkmark")
                        } else {
                            Text("\(value)%")
                        }
                    }
                }
            } label: {
                Label("Progress", systemImage: "percent")
            }
        }
        Menu {
            ForEach(ScheduleTaskStatus.allCases) { status in
                Button {
                    store.setStatus(status, taskId: task.id)
                } label: {
                    Label(status.label, systemImage: task.status == status ? "checkmark" : status.systemImage)
                }
            }
        } label: {
            Label("Status", systemImage: "flag")
        }
        Button {
            onEditTask(task.id)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button(role: .destructive) {
            pendingDelete = task
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// One task row. Wide layouts add responsible and duration columns.
struct ScheduleTaskRow: View {
    let task: ScheduleTask
    let phaseColor: Color
    let today: CalendarDay
    var isWide = false
    var hasConflict = false

    var body: some View {
        let behind = task.isBehind(today: today)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(behind ? ScheduleStyle.behind : phaseColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if task.isMilestone {
                        MilestoneGlyph(color: phaseColor, size: 12)
                    }
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if hasConflict {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(ScheduleStyle.conflict)
                            .accessibilityLabel("Starts before a predecessor finishes")
                    }
                }
                HStack(spacing: 6) {
                    Text(ScheduleDateFormat.range(task))
                    if !task.isMilestone {
                        Text("·")
                        Text(ScheduleDateFormat.duration(task))
                    }
                    if !isWide, let name = task.responsibleName {
                        Text("·")
                        Text(name).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !task.isMilestone {
                    HStack(spacing: 8) {
                        ScheduleProgressBar(progress: task.progress,
                                            tint: behind ? ScheduleStyle.behind : phaseColor)
                        Text("\(task.progress)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            if isWide {
                Spacer(minLength: 12)
                Text(task.responsibleName ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(task.responsibleName == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)
            }
            Spacer(minLength: 0)
            ScheduleStatusBadge(task: task, today: today)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
