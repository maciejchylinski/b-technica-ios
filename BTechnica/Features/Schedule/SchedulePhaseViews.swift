import SwiftUI

/// Create / rename / recolor / delete a phase. Phase names are free text.
struct SchedulePhaseEditor: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var phase: SchedulePhase
    @State private var errorText: String?
    @State private var confirmDelete = false

    init(draft: SchedulePhase, isNew: Bool) {
        self.isNew = isNew
        _phase = State(initialValue: draft)
    }

    var body: some View {
        let taskCount = store.tasks(inPhase: phase.id).count
        NavigationStack {
            Form {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(ScheduleStyle.behind)
                    }
                }
                Section {
                    TextField("Phase name", text: $phase.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("schedulePhaseNameField")
                } footer: {
                    Text("Use any grouping that fits the project — stage, floor, zone or trade.")
                }
                Section("Color") {
                    PhaseColorPicker(selection: $phase.colorHex)
                }
                if !isNew {
                    Section {
                        Button("Delete phase", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if taskCount > 0 {
                            Text("Deleting removes its \(taskCount) task\(taskCount == 1 ? "" : "s"). Move tasks to another phase first to keep them.")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New phase" : "Edit phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.savePhase(phase)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(phase.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("schedulePhaseSaveButton")
                }
            }
            .confirmationDialog(
                taskCount > 0 ? "Delete “\(phase.name)” and its \(taskCount) tasks?" : "Delete “\(phase.name)”?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.deletePhase(id: phase.id)
                    dismiss()
                }
            }
        }
    }
}

/// Phase list with drag-to-reorder.
struct SchedulePhasesView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: SchedulePhase?
    @State private var creating: SchedulePhase?

    var body: some View {
        NavigationStack {
            List {
                if store.phases.isEmpty {
                    Text("No phases yet. Phases group tasks on the list and the Gantt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.phases) { phase in
                    Button {
                        editing = phase
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(ScheduleStyle.color(hex: phase.colorHex))
                                .frame(width: 14, height: 14)
                            Text(phase.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(store.tasks(inPhase: phase.id).count)")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 36)
                    }
                }
                .onMove { store.movePhases(from: $0, to: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Phases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = store.newPhaseDraft()
                    } label: {
                        Label("Add phase", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { phase in
                SchedulePhaseEditor(draft: phase, isNew: false)
                    .environmentObject(store)
            }
            .sheet(item: $creating) { phase in
                SchedulePhaseEditor(draft: phase, isNew: true)
                    .environmentObject(store)
            }
        }
    }
}

/// Create or edit the schedule's name and description; edit mode can delete it.
struct ScheduleFormSheet: View {
    enum Mode {
        case create(defaultName: String)
        case edit
    }

    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var name = ""
    @State private var details = ""
    @State private var confirmDelete = false
    @State private var didLoad = false

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Schedule name", text: $name)
                        .accessibilityIdentifier("scheduleNameField")
                    TextField("Description (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    if isCreate {
                        Text("Each project has one schedule. Phases and tasks are added next — no fixed phase names are required.")
                    }
                }
                if !isCreate {
                    Section {
                        LabeledContent("Phases", value: "\(store.phases.count)")
                        LabeledContent("Tasks and milestones", value: "\(store.tasks.count)")
                        LabeledContent("Storage", value: "On this device")
                    }
                    Section {
                        Button("Delete schedule", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deletes all phases, tasks and dependencies of this schedule.")
                    }
                }
            }
            .navigationTitle(isCreate ? "New schedule" : "Schedule settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreate ? "Create" : "Save") {
                        let ok = isCreate
                            ? store.createSchedule(name: name, details: details)
                            : store.updateSchedule(name: name, details: details)
                        if ok { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("scheduleSaveButton")
                }
            }
            .confirmationDialog("Delete the whole schedule?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete schedule", role: .destructive) {
                    store.deleteSchedule()
                    dismiss()
                }
            } message: {
                Text("\(store.tasks.count) tasks and \(store.phases.count) phases will be removed. This can’t be undone.")
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                switch mode {
                case .create(let defaultName):
                    name = defaultName
                case .edit:
                    name = store.schedule?.name ?? ""
                    details = store.schedule?.details ?? ""
                }
            }
        }
    }
}
