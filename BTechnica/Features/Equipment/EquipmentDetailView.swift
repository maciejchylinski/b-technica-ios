import SwiftUI

/// Equipment detail: current holder, issue / return / damaged / lost actions,
/// checkout history across projects, and the full event log.
struct EquipmentDetailView: View {
    @ObservedObject var equipment: EquipmentStore
    let equipmentId: UUID

    @StateObject private var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var sheet: EquipmentSheet?
    @State private var confirmDelete = false
    @State private var actionError: String?

    init(equipment: EquipmentStore, equipmentId: UUID) {
        self.equipment = equipment
        self.equipmentId = equipmentId
        _contacts = StateObject(wrappedValue: ContactsStore(userId: equipment.userId, projectId: equipment.projectId))
    }

    private var item: EquipmentItem? { equipment.item(id: equipmentId) }
    private var active: EquipmentCheckout? { equipment.activeCheckout(for: equipmentId) }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                ContentUnavailableView("Equipment not found", systemImage: "shippingbox")
            }
        }
        .navigationTitle(item?.item ?? "Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { sheet = .edit }
                    .disabled(item == nil)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit:
                EquipmentEditor(equipment: equipment, itemId: equipmentId)
            case .issue(let handOver):
                EquipmentIssueSheet(equipment: equipment, contacts: contacts, equipmentId: equipmentId, handOver: handOver)
            case .returnItem:
                EquipmentReturnSheet(equipment: equipment, equipmentId: equipmentId)
            case .mark(let status):
                EquipmentStatusNotesSheet(equipment: equipment, equipmentId: equipmentId, status: status)
            }
        }
        .alert("Can't update",
               isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func content(_ item: EquipmentItem) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: item.normalizedStatus.systemImage)
                        .font(.title)
                        .foregroundStyle(item.normalizedStatus.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.normalizedStatus.label)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(item.normalizedStatus.color)
                        if let category = item.displayCategory {
                            Text(category).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let active {
                    holderCard(active)
                }
            }

            Section("Actions") {
                if item.canIssue {
                    actionButton("Issue / hand out", systemImage: "arrow.up.forward.circle") {
                        sheet = .issue(handOver: false)
                    }
                }
                if item.normalizedStatus == .issued {
                    actionButton("Return", systemImage: "arrow.uturn.backward.circle") { sheet = .returnItem }
                    actionButton("Hand over to someone else", systemImage: "arrow.left.arrow.right.circle") {
                        sheet = .issue(handOver: true)
                    }
                }
                if item.normalizedStatus != .damaged {
                    actionButton("Mark damaged", systemImage: "wrench.and.screwdriver", tint: .orange) {
                        sheet = .mark(.damaged)
                    }
                }
                if item.normalizedStatus != .lost {
                    actionButton("Mark lost", systemImage: "questionmark.circle", tint: .red) {
                        sheet = .mark(.lost)
                    }
                }
                if item.canRestore {
                    actionButton("Back in service", systemImage: "checkmark.circle", tint: .green) {
                        actionError = equipment.restore(id: item.id, notes: nil)
                    }
                }
            }

            Section("Details") {
                LabeledContent("Identifier", value: item.displayIdentifier ?? "—")
                LabeledContent("Serial number", value: item.displaySerialNumber ?? "—")
                if active == nil, let location = item.displayLocation {
                    LabeledContent("Last location", value: location)
                }
                if let notes = item.displayNotes {
                    Text(notes)
                }
            }

            let history = equipment.checkouts(for: item.id)
            if !history.isEmpty {
                Section("Checkouts") {
                    ForEach(history) { checkout in
                        CheckoutRow(checkout: checkout, projectName: projectLabel(checkout.projectId))
                    }
                }
            }

            Section("History") {
                let events = item.history.sorted { $0.date > $1.date }
                if events.isEmpty {
                    Text("No history yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        EquipmentHistoryRow(event: event, projectName: projectLabel(event.projectId))
                    }
                }
            }

            Section {
                Button("Delete equipment", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("The register is shared by all your projects. Deleting removes the item and its history everywhere.")
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Delete \(item.item)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete equipment", role: .destructive) {
                if let error = equipment.delete(id: item.id) {
                    actionError = error
                } else {
                    dismiss()
                }
            }
        } message: {
            Text(active == nil
                 ? "History is removed too. This cannot be undone."
                 : "It is currently issued to \(active?.recipientName ?? ""). History is removed too. This cannot be undone.")
        }
    }

    private func holderCard(_ checkout: EquipmentCheckout) -> some View {
        let phone: String? = {
            switch checkout.recipient {
            case .person(let id): return contacts.person(id: id)?.phone
            case .company(let id): return contacts.company(id: id)?.phone
            case .freeText: return nil
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text("CURRENTLY WITH")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: EquipmentHolder(checkout).systemImage)
                    .font(.title2)
                    .foregroundStyle(Theme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkout.recipientName)
                        .font(.headline)
                    Text(projectLabel(checkout.projectId) ?? "No project")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = ContactURL.phone(phone) {
                    Button { openURL(url) } label: {
                        Image(systemName: "phone.fill")
                            .frame(width: 44, height: 44)
                            .background(Theme.blue.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Call \(checkout.recipientName)")
                }
            }
            Text(["Since \(checkout.issuedDate.formatted(date: .abbreviated, time: .shortened))", checkout.location]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notes = checkout.notes {
                Text(notes).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func projectLabel(_ id: UUID?) -> String? {
        guard let id else { return nil }
        if id == equipment.projectId { return "This project" }
        return equipment.projectName(id) ?? "Other project"
    }

    private func actionButton(_ title: String, systemImage: String, tint: Color = Theme.blue,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
                .frame(minHeight: Theme.touchTarget - 8)
        }
    }
}

private enum EquipmentSheet: Identifiable {
    case edit
    case issue(handOver: Bool)
    case returnItem
    case mark(EquipmentStatus)

    var id: String {
        switch self {
        case .edit: return "edit"
        case .issue(let handOver): return "issue-\(handOver)"
        case .returnItem: return "return"
        case .mark(let status): return "mark-\(status.rawValue)"
        }
    }
}

private struct CheckoutRow: View {
    let checkout: EquipmentCheckout
    let projectName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(checkout.recipientName, systemImage: EquipmentHolder(checkout).systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(checkout.isActive ? "Active" : (checkout.outcome?.label ?? "Closed"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(checkout.isActive ? Theme.blue : .secondary)
            }
            Text(dateRange)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail = [projectName, checkout.location].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let notes = checkout.returnNotes {
                Text(notes).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var dateRange: String {
        let start = checkout.issuedDate.formatted(date: .abbreviated, time: .omitted)
        guard let end = checkout.returnedDate else { return "\(start) → now" }
        return "\(start) → \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct EquipmentHistoryRow: View {
    let event: EquipmentEvent
    let projectName: String?

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
            if let detail = [event.person, event.location, projectName].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let notes = event.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Issue (or hand over) to a project contact or a free-text recipient.
private struct EquipmentIssueSheet: View {
    @ObservedObject var equipment: EquipmentStore
    @ObservedObject var contacts: ContactsStore
    let equipmentId: UUID
    let handOver: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var kind: RecipientKind = .person
    @State private var personId: UUID?
    @State private var companyId: UUID?
    @State private var freeText = ""
    @State private var search = ""
    @State private var location = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var errorMessage: String?

    private enum RecipientKind: String, CaseIterable, Identifiable {
        case person, company, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .person: return "Person"
            case .company: return "Company"
            case .other: return "Other"
            }
        }
    }

    private var recipient: EquipmentRecipient? {
        switch kind {
        case .person: return personId.map(EquipmentRecipient.person)
        case .company: return companyId.map(EquipmentRecipient.company)
        case .other:
            return freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .freeText
        }
    }

    private var people: [ContactPerson] {
        contacts.projectPeople.filter { contacts.matches(.person($0.id), query: search) }
    }

    private var companies: [ContactCompany] {
        contacts.projectCompanies.filter { contacts.matches(.company($0.id), query: search) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if handOver, let active = equipment.activeCheckout(for: equipmentId) {
                    Section {
                        LabeledContent("Currently with", value: active.recipientName)
                    } footer: {
                        Text("The current checkout is closed and a new one starts in this project.")
                    }
                }

                Section {
                    Picker("Recipient", selection: $kind) {
                        ForEach(RecipientKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kind != .other {
                        TextField("Search project contacts", text: $search)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Issue to")
                }

                recipientSection

                Section {
                    TextField("Location (optional)", text: $location)
                        .textInputAutocapitalization(.words)
                    DatePicker("Date", selection: $date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(handOver ? "Hand over" : "Issue equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(handOver ? "Hand over" : "Issue") { save() }
                        .disabled(recipient == nil)
                        .fontWeight(.semibold)
                }
            }
            .alert("Can't issue",
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                contacts.reload()
                if contacts.projectPeople.isEmpty {
                    kind = contacts.projectCompanies.isEmpty ? .other : .company
                }
            }
        }
    }

    @ViewBuilder
    private var recipientSection: some View {
        switch kind {
        case .person:
            Section {
                if people.isEmpty {
                    emptyContacts("No people in this project's contacts.")
                }
                ForEach(people) { person in
                    selectableRow(
                        title: person.fullName,
                        subtitle: [contacts.link(for: .person(person.id))?.role ?? person.jobTitle,
                                   contacts.company(id: person.companyId)?.name].compactMap { $0 }.joined(separator: " · "),
                        isSelected: personId == person.id
                    ) { personId = person.id }
                }
            }
        case .company:
            Section {
                if companies.isEmpty {
                    emptyContacts("No companies in this project's contacts.")
                }
                ForEach(companies) { company in
                    selectableRow(
                        title: company.name,
                        subtitle: contacts.link(for: .company(company.id))?.role ?? company.trade ?? "",
                        isSelected: companyId == company.id
                    ) { companyId = company.id }
                }
            }
        case .other:
            Section {
                TextField("Name", text: $freeText)
                    .textInputAutocapitalization(.words)
            } footer: {
                Text("For someone who is not in the project contacts.")
            }
        }
    }

    private func emptyContacts(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(search.isEmpty ? message : "No matches.")
                .foregroundStyle(.secondary)
            if search.isEmpty {
                Text("Add contacts under More → Contacts, or use Other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectableRow(title: String, subtitle: String, isSelected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.blue : .secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        guard let recipient else { return }
        if let error = equipment.issue(
            id: equipmentId,
            recipient: recipient,
            recipientName: kind == .other ? freeText : nil,
            location: location,
            date: date,
            notes: notes,
            handOver: handOver
        ) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

private struct EquipmentReturnSheet: View {
    @ObservedObject var equipment: EquipmentStore
    let equipmentId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var condition: EquipmentReturnCondition = .good
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let active = equipment.activeCheckout(for: equipmentId) {
                    Section {
                        LabeledContent("Returned by", value: active.recipientName)
                        LabeledContent("Issued", value: active.issuedDate.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    DatePicker("Return date", selection: $date)
                    Picker("Condition", selection: $condition) {
                        ForEach(EquipmentReturnCondition.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text(condition == .damaged
                         ? "The item is marked damaged and can't be issued until it is back in service."
                         : "The item becomes available for the next checkout.")
                }
            }
            .navigationTitle("Return equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Return") {
                        if let error = equipment.returnItem(id: equipmentId, date: date, condition: condition, notes: notes) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Can't return",
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct EquipmentStatusNotesSheet: View {
    @ObservedObject var equipment: EquipmentStore
    let equipmentId: UUID
    let status: EquipmentStatus

    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    if let active = equipment.activeCheckout(for: equipmentId) {
                        Text("Closes the checkout held by \(active.recipientName); the history keeps who had it.")
                    } else {
                        Text("Optional context for the history entry.")
                    }
                }
            }
            .navigationTitle(status == .damaged ? "Mark damaged" : "Mark lost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let error = equipment.mark(id: equipmentId, status: status, notes: notes) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Can't update",
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
