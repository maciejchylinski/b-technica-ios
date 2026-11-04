import SwiftUI

/// Task details with quick progress / status updates and dependency management.
/// Pushed from lists, or shown in the inspector when tapped on the Gantt.
struct ScheduleTaskDetailView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    let taskId: UUID
    var onClose: (() -> Void)?

    @State private var showEditor = false
    @State private var showPredecessorPicker = false
    @State private var confirmDelete = false
    @State private var draftProgress: Double?
    @State private var actionError: String?

    var body: some View {
        Group {
            if let task = store.task(id: taskId) {
                content(task)
            } else {
                ContentUnavailableView("Task not found", systemImage: "questionmark.square.dashed",
                                       description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(store.task(id: taskId)?.isMilestone == true ? "Milestone" : "Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            if store.task(id: taskId) != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showEditor = true }
                        .accessibilityIdentifier("scheduleTaskEditButton")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let task = store.task(id: taskId) {
                ScheduleTaskEditor(draft: task, isNew: false)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showPredecessorPicker) {
            if let task = store.task(id: taskId) {
                SchedulePredecessorPicker(
                    taskId: task.id,
                    initialSelection: store.predecessors(of: task.id).map(\.task.id)
                ) { selection in
                    guard let current = store.task(id: taskId) else { throw ScheduleValidationError.notFound }
                    try store.saveTask(current, predecessorIds: selection)
                }
                .environmentObject(store)
            }
        }
        .alert("Couldn’t update", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func content(_ task: ScheduleTask) -> some View {
        let today = CalendarDay.today()
        let phase = store.phase(id: task.phaseId)
        let conflicts = store.dependencyConflicts(for: task)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if task.isMilestone {
                            MilestoneGlyph(color: ScheduleStyle.color(hex: phase?.colorHex ?? GanttLayout.unphasedColorHex), size: 16)
                        }
                        Text(task.title)
                            .font(.title3.weight(.semibold))
                    }
                    HStack(spacing: 8) {
                        ScheduleStatusBadge(task: task, today: today)
                        if let phase {
                            Label(phase.name, systemImage: "circle.fill")
                                .labelStyle(PhaseLabelStyle(color: ScheduleStyle.color(hex: phase.colorHex)))
                        } else {
                            Text("No phase").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    if !task.details.isEmpty {
                        Text(task.details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            progressSection(task)

            Section("Dates") {
                LabeledContent(task.isMilestone ? "Date" : "Start", value: ScheduleDateFormat.weekday(task.startDay))
                if !task.isMilestone {
                    LabeledContent("Finish", value: ScheduleDateFormat.weekday(task.finishDay))
                    LabeledContent("Duration", value: ScheduleDateFormat.duration(task))
                }
                if task.isOverdue(today: today) {
                    Label("Finish date passed \(ScheduleDateFormat.relative(task.finishDay, today: today))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScheduleStyle.behind)
                        .font(.subheadline)
                }
                if !conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Starts before \(conflicts.map(\.title).joined(separator: ", ")) finishes.",
                              systemImage: "arrow.triangle.branch")
                            .foregroundStyle(ScheduleStyle.conflict)
                            .font(.subheadline)
                        Button("Move after predecessors") { shiftAfterPredecessors(task, conflicts: conflicts) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Responsible") {
                if let name = task.responsibleName {
                    Label(name, systemImage: "person.crop.circle")
                } else {
                    Text("Not assigned").foregroundStyle(.secondary)
                }
            }

            dependencySection(task, today: today)

            if !task.notes.isEmpty {
                Section("Notes") {
                    Text(task.notes)
                        .font(.subheadline)
                }
            }

            Section {
                Button("Delete \(task.isMilestone ? "milestone" : "task")", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteTask(id: task.id)
                if let onClose { onClose() } else { dismiss() }
            }
        } message: {
            Text("Its dependencies are removed too. This can’t be undone.")
        }
    }

    @ViewBuilder
    private func progressSection(_ task: ScheduleTask) -> some View {
        Section("Progress") {
            if !task.isMilestone {
                let shown = Int(draftProgress ?? Double(task.progress))
                HStack {
                    Text("\(shown)%")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .frame(width: 72, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { draftProgress ?? Double(task.progress) },
                            set: { draftProgress = $0 }
                        ),
                        in: 0...100,
                        step: 5
                    ) { editing in
                        if !editing, let value = draftProgress {
                            store.setProgress(Int(value), taskId: task.id)
                            draftProgress = nil
                        }
                    }
                    .accessibilityLabel("Progress")
                }
                HStack(spacing: 8) {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                        Button("\(value)%") { store.setProgress(value, taskId: task.id) }
                            .buttonStyle(.bordered)
                            .tint(task.progress == value ? Theme.blue : .secondary)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 8) {
                statusButton(.inProgress, title: "Start", systemImage: "play.fill", task: task)
                statusButton(.completed, title: "Complete", systemImage: "checkmark", task: task)
                statusButton(.delayed, title: "Delayed", systemImage: "exclamationmark.triangle", task: task)
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusButton(_ status: ScheduleTaskStatus, title: String, systemImage: String, task: ScheduleTask) -> some View {
        Button {
            store.setStatus(task.status == status ? (status == .completed ? .inProgress : .planned) : status, taskId: task.id)
        } label: {
            Label(title, systemImage: task.status == status ? "checkmark.circle.fill" : systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .tint(task.status == status ? ScheduleStyle.statusColor(status) : .secondary)
        .accessibilityAddTraits(task.status == status ? .isSelected : [])
    }

    @ViewBuilder
    private func dependencySection(_ task: ScheduleTask, today: CalendarDay) -> some View {
        let predecessors = store.predecessors(of: task.id)
        let successors = store.successors(of: task.id)
        Section {
            ForEach(predecessors, id: \.dependency.id) { item in
                dependencyRow(item.task, conflict: ScheduleRules.violatesFinishToStart(predecessor: item.task, successor: task), today: today)
                    .swipeActions {
                        Button("Remove", role: .destructive) { store.removeDependency(id: item.dependency.id) }
                    }
            }
            Button {
                showPredecessorPicker = true
            } label: {
                Label(predecessors.isEmpty ? "Add predecessor" : "Edit predecessors", systemImage: "arrow.turn.down.right")
            }
        } header: {
            Text("Waits for (finish-to-start)")
        } footer: {
            Text("This activity can start once these are finished.")
        }
        if !successors.isEmpty {
            Section("Followed by") {
                ForEach(successors, id: \.dependency.id) { item in
                    dependencyRow(item.task, conflict: ScheduleRules.violatesFinishToStart(predecessor: task, successor: item.task), today: today)
                }
            }
        }
    }

    private func dependencyRow(_ other: ScheduleTask, conflict: Bool, today: CalendarDay) -> some View {
        NavigationLink(value: ScheduleTaskRoute(id: other.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(other.title).font(.subheadline)
                    Text(ScheduleDateFormat.range(other)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScheduleStyle.conflict)
                        .accessibilityLabel("Date conflict")
                }
                ScheduleStatusBadge(task: other, today: today)
            }
        }
    }

    private func shiftAfterPredecessors(_ task: ScheduleTask, conflicts: [ScheduleTask]) {
        guard let earliest = conflicts.map(ScheduleRules.earliestStart(after:)).max() else { return }
        var moved = task
        let shift = task.startDay.days(to: earliest)
        moved.startDay = earliest
        moved.finishDay = task.finishDay.adding(days: shift)
        do {
            try store.saveTask(moved, predecessorIds: nil)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct PhaseLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            configuration.title
        }
        .foregroundStyle(.secondary)
    }
}

/// Multi-select of finish-to-start predecessors. Tasks that would create a loop
/// are shown disabled with the reason.
struct SchedulePredecessorPicker: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    let taskId: UUID
    let onSave: ([UUID]) throws -> Void

    @State private var selection: [UUID]
    @State private var searchText = ""
    @State private var errorText: String?

    init(taskId: UUID, initialSelection: [UUID], onSave: @escaping ([UUID]) throws -> Void) {
        self.taskId = taskId
        self.onSave = onSave
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        let blocked = ScheduleRules.blockedPredecessors(for: taskId, edges: store.edges)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let candidates = store.tasks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: candidates, by: \.phaseId)
        let groupKeys: [UUID?] = store.phases.map(\.id) + (grouped[nil] != nil ? [nil] : [])

        NavigationStack {
            List {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(ScheduleStyle.behind)
                    }
                }
                ForEach(groupKeys.filter { grouped[$0] != nil }, id: \.self) { key in
                    Section(store.phase(id: key)?.name ?? "No phase") {
                        ForEach(grouped[key] ?? []) { candidate in
                            row(candidate, isBlocked: blocked.contains(candidate.id))
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search tasks")
            .navigationTitle("Predecessors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        do {
                            try onSave(selection)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ candidate: ScheduleTask, isBlocked: Bool) -> some View {
        let isSelected = selection.contains(candidate.id)
        return Button {
            if isSelected {
                selection.removeAll { $0 == candidate.id }
            } else {
                selection.append(candidate.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .foregroundStyle(isBlocked ? .secondary : .primary)
                    Text(candidate.id == taskId
                         ? "This task"
                         : (isBlocked ? "Already follows this task — would create a loop" : ScheduleDateFormat.range(candidate)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.blue)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isBlocked && !isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
