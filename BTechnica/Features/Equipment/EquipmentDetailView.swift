import SwiftUI

/// Equipment detail: current status, issue/return actions, and event history.
struct EquipmentDetailView: View {
    @EnvironmentObject private var store: AppStore

    let equipmentId: UUID

    @State private var showEditor = false
    @State private var showIssue = false
    @State private var showReturn = false
    @State private var statusNotesPrompt: StatusNotesPrompt?
    @State private var actionError: String?

    private var item: EquipmentItem? {
        store.equipment(id: equipmentId)
    }

    private var historyNewestFirst: [EquipmentEvent] {
        (item?.history ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if let item {
                List {
                    Section {
                        LabeledContent("Status", value: item.status.label)
                        if let category = item.displayCategory {
                            LabeledContent("Type", value: category)
                        }
                        if let identifier = item.displayIdentifier {
                            LabeledContent("Identifier", value: identifier)
                        }
                        if item.status == .issued, let issuedTo = item.displayIssuedTo {
                            LabeledContent("Issued to", value: issuedTo)
                        }
                        if let location = item.displayLocation {
                            LabeledContent("Location", value: location)
                        }
                        if let issuedDate = item.issuedDate {
                            LabeledContent("Issued", value: issuedDate.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let returnedDate = item.returnedDate {
                            LabeledContent("Returned", value: returnedDate.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let notes = item.displayNotes {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(notes)
                            }
                        }
                    }

                    Section("Actions") {
                        if item.canIssue {
                            Button("Issue / hand out") { showIssue = true }
                        }
                        if item.canReturn {
                            Button("Return") { showReturn = true }
                        }
                        if item.status != .damaged {
                            Button("Mark damaged") {
                                statusNotesPrompt = StatusNotesPrompt(status: .damaged)
                            }
                        }
                        if item.status != .lost {
                            Button("Mark lost") {
                                statusNotesPrompt = StatusNotesPrompt(status: .lost)
                            }
                        }
                        if item.status == .returned || item.status == .damaged || item.status == .lost {
                            Button("Mark available") {
                                if let reason = store.markEquipmentAvailable(id: item.id) {
                                    actionError = reason
                                }
                            }
                        }
                    }

                    Section("History") {
                        if historyNewestFirst.isEmpty {
                            Text("No history yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(historyNewestFirst) { event in
                                EquipmentHistoryRow(event: event)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("Equipment not found", systemImage: "shippingbox")
            }
        }
        .navigationTitle(item?.item ?? "Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showEditor = true }
                    .disabled(item == nil)
            }
        }
        .sheet(isPresented: $showEditor) {
            EquipmentEditor(mode: .edit(equipmentId))
                .environmentObject(store)
        }
        .sheet(isPresented: $showIssue) {
            EquipmentIssueSheet(equipmentId: equipmentId)
                .environmentObject(store)
        }
        .sheet(isPresented: $showReturn) {
            EquipmentReturnSheet(equipmentId: equipmentId)
                .environmentObject(store)
        }
        .sheet(item: $statusNotesPrompt) { prompt in
            EquipmentStatusNotesSheet(equipmentId: equipmentId, status: prompt.status)
                .environmentObject(store)
        }
        .alert("Can't update",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }
}

private struct StatusNotesPrompt: Identifiable {
    let status: EquipmentStatus
    var id: String { status.rawValue }
}

private struct EquipmentHistoryRow: View {
    let event: EquipmentEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.type.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let person = EquipmentEvent.nonEmpty(event.person) {
                Text(person)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let location = EquipmentEvent.nonEmpty(event.location) {
                Text(location)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let notes = EquipmentEvent.nonEmpty(event.notes) {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Issue / hand-out form.
private struct EquipmentIssueSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let equipmentId: UUID

    @State private var issuedTo = ""
    @State private var location = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var errorMessage: String?

    private var canSave: Bool {
        !issuedTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Issued to", text: $issuedTo)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Required. Person or company receiving the item.")
                }

                Section {
                    TextField("Location (optional)", text: $location)
                        .textInputAutocapitalization(.words)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Issue equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Issue") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .alert("Can't issue",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        if let reason = store.issueEquipment(
            id: equipmentId,
            issuedTo: issuedTo,
            location: location,
            date: date,
            notes: notes
        ) {
            errorMessage = reason
            return
        }
        dismiss()
    }
}

/// Return form.
private struct EquipmentReturnSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let equipmentId: UUID

    @State private var date = Date()
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Return date", selection: $date, displayedComponents: .date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Return equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Return") { save() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Can't return",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        if let reason = store.returnEquipment(id: equipmentId, date: date, notes: notes) {
            errorMessage = reason
            return
        }
        dismiss()
    }
}

/// Optional notes when marking damaged or lost.
private struct EquipmentStatusNotesSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let equipmentId: UUID
    let status: EquipmentStatus

    @State private var notes = ""
    @State private var errorMessage: String?

    private var title: String {
        status == .damaged ? "Mark damaged" : "Mark lost"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Optional context for the history entry.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Can't update",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        if let reason = store.markEquipment(id: equipmentId, status: status, notes: notes) {
            errorMessage = reason
            return
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        EquipmentDetailView(equipmentId: UUID())
            .environmentObject(AppStore())
    }
}
