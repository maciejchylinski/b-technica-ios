import SwiftUI

/// Create / edit a task or milestone. Dates are calendar days; moving the start
/// keeps the duration, and the finish can never be set before the start.
struct ScheduleTaskEditor: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool

    @State private var task: ScheduleTask
    @State private var predecessorIds: [UUID]
    @State private var errorText: String?
    @State private var showPredecessors = false
    @State private var confirmDelete = false

    init(draft: ScheduleTask, isNew: Bool) {
        self.isNew = isNew
        _task = State(initialValue: draft)
        _predecessorIds = State(initialValue: [])
    }

    private var canSave: Bool {
        !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(ScheduleStyle.behind)
                    }
                }

                Section {
                    TextField(task.isMilestone ? "Milestone name" : "Task title", text: $task.title)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("scheduleTaskTitleField")
                    TextField("Description", text: $task.details, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Picker("Type", selection: kindBinding) {
                        ForEach(ScheduleTaskKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Phase", selection: $task.phaseId) {
                        Text("No phase").tag(UUID?.none)
                        ForEach(store.phases) { phase in
                            Text(phase.name).tag(Optional(phase.id))
                        }
                    }
                }

                datesSection

                progressSection

                Section {
                    TextField("Person or contractor", text: responsibleBinding)
                        .textInputAutocapitalization(.words)
                    if !store.responsibleSuggestions.isEmpty {
                        Menu {
                            ForEach(store.responsibleSuggestions, id: \.self) { name in
                                Button(name) { task.responsibleName = name }
                            }
                            if task.responsibleName != nil {
                                Divider()
                                Button("Clear", role: .destructive) { task.responsibleName = nil }
                            }
                        } label: {
                            Label("Choose existing", systemImage: "person.2")
                        }
                    }
                } header: {
                    Text("Responsible")
                } footer: {
                    Text("Optional free text. Linking to project contacts will come with the Contacts module.")
                }

                Section {
                    Button {
                        showPredecessors = true
                    } label: {
                        HStack {
                            Label("Waits for", systemImage: "arrow.turn.down.right")
                            Spacer()
                            Text(predecessorSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Dependencies")
                } footer: {
                    Text("Finish-to-start: this activity starts after the selected ones finish.")
                }

                Section("Notes") {
                    TextField("Notes", text: $task.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if !isNew {
                    Section {
                        Button("Delete \(task.isMilestone ? "milestone" : "task")", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
            }
            .navigationTitle(isNew ? (task.isMilestone ? "New milestone" : "New task") : "Edit \(task.isMilestone ? "milestone" : "task")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("scheduleTaskSaveButton")
                }
            }
            .sheet(isPresented: $showPredecessors) {
                SchedulePredecessorPicker(taskId: task.id, initialSelection: predecessorIds) { selection in
                    // Validate against the current graph before accepting.
                    let edges = store.edges
                    try ScheduleRules.validatePredecessors(selection, of: task.id, existing: edges)
                    predecessorIds = selection
                }
                .environmentObject(store)
            }
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.deleteTask(id: task.id)
                    dismiss()
                }
            }
            .onAppear {
                if !isNew {
                    predecessorIds = store.predecessors(of: task.id).map(\.task.id)
                }
            }
        }
    }

    // MARK: - Sections

    private var datesSection: some View {
        Section {
            DatePicker(task.isMilestone ? "Date" : "Start", selection: startBinding, displayedComponents: .date)
            if !task.isMilestone {
                DatePicker("Finish", selection: finishBinding, in: task.startDay.date()..., displayedComponents: .date)
                Stepper(value: durationBinding, in: 1...ScheduleRules.maxDurationDays) {
                    LabeledContent("Duration", value: ScheduleDateFormat.duration(task))
                }
            }
            if let warning = predecessorWarning {
                VStack(alignment: .leading, spacing: 6) {
                    Label(warning.message, systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(ScheduleStyle.conflict)
                    Button("Start \(ScheduleDateFormat.short(warning.earliest)) instead") {
                        let duration = max(1, task.durationDays)
                        task.startDay = warning.earliest
                        task.finishDay = task.isMilestone ? warning.earliest : warning.earliest.adding(days: duration - 1)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        } header: {
            Text("Dates")
        } footer: {
            Text(task.isMilestone ? "A milestone marks a single day." : "Calendar days, including start and finish.")
        }
    }

    private var progressSection: some View {
        Section("Status") {
            Picker("Status", selection: statusBinding) {
                ForEach(ScheduleTaskStatus.allCases) { status in
                    Label(status.label, systemImage: status.systemImage).tag(status)
                }
            }
            if !task.isMilestone {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Progress", value: "\(task.progress)%")
                    Slider(value: progressBinding, in: 0...100, step: 5)
                        .accessibilityLabel("Progress")
                }
            }
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<ScheduleTaskKind> {
        Binding(
            get: { task.kind },
            set: { kind in
                task.kind = kind
                if kind == .milestone { task.finishDay = task.startDay }
            }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { task.startDay.date() },
            set: { date in
                let duration = max(1, task.durationDays)
                let day = CalendarDay(date)
                task.startDay = day
                task.finishDay = task.isMilestone ? day : day.adding(days: duration - 1)
            }
        )
    }

    private var finishBinding: Binding<Date> {
        Binding(
            get: { task.finishDay.date() },
            set: { date in task.finishDay = max(CalendarDay(date), task.startDay) }
        )
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { max(1, task.durationDays) },
            set: { days in task.finishDay = task.startDay.adding(days: max(1, days) - 1) }
        )
    }

    private var statusBinding: Binding<ScheduleTaskStatus> {
        Binding(
            get: { task.status },
            set: { task = ScheduleRules.applyingStatus($0, to: task) }
        )
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { Double(task.progress) },
            set: { task = ScheduleRules.applyingProgress(Int($0), to: task) }
        )
    }

    private var responsibleBinding: Binding<String> {
        Binding(
            get: { task.responsibleName ?? "" },
            set: { task.responsibleName = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Derived

    private var predecessorSummary: String {
        let names = predecessorIds.compactMap { store.task(id: $0)?.title }
        switch names.count {
        case 0: return "None"
        case 1: return names[0]
        default: return "\(names.count) activities"
        }
    }

    private var predecessorWarning: (message: String, earliest: CalendarDay)? {
        let preds = predecessorIds.compactMap { store.task(id: $0) }
        let late = preds.filter { ScheduleRules.violatesFinishToStart(predecessor: $0, successor: task) }
        guard let earliest = late.map(ScheduleRules.earliestStart(after:)).max() else { return nil }
        let names = late.map(\.title).joined(separator: ", ")
        return ("Starts before \(names) finishes.", earliest)
    }

    private func save() {
        do {
            try store.saveTask(task, predecessorIds: predecessorIds)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
