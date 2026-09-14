import SwiftUI

/// Edit title, details, status, contractor and discipline for an existing issue.
struct IssueEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let issueId: UUID

    @State private var title = ""
    @State private var details = ""
    @State private var status: IssueStatus = .open
    @State private var selectedDisciplineName = ""
    @State private var selectedContractorName = ""
    @State private var showAddDiscipline = false
    @State private var showAddContractor = false
    @State private var newDisciplineName = ""
    @State private var newContractorName = ""

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedDisciplines: [Discipline] {
        store.data.disciplines.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var sortedContractors: [Contractor] {
        store.data.contractors.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("Description", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Picker("Status", selection: $status) {
                        ForEach(IssueStatus.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                } footer: {
                    Text("Open and In progress count as active. Resolved and Closed are done.")
                }

                Section {
                    if sortedDisciplines.isEmpty && selectedDisciplineName.isEmpty {
                        Text("No disciplines yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Discipline", selection: $selectedDisciplineName) {
                            Text("None").tag("")
                            ForEach(sortedDisciplines) { item in
                                Text(item.name).tag(item.name)
                            }
                            if !selectedDisciplineName.isEmpty,
                               !sortedDisciplines.contains(where: { $0.name == selectedDisciplineName }) {
                                Text(selectedDisciplineName).tag(selectedDisciplineName)
                            }
                        }
                    }
                    Button("Add discipline") {
                        newDisciplineName = ""
                        showAddDiscipline = true
                    }
                } header: {
                    Text("Discipline / category")
                }

                Section {
                    if sortedContractors.isEmpty && selectedContractorName.isEmpty {
                        Text("No contractors yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Contractor", selection: $selectedContractorName) {
                            Text("None").tag("")
                            ForEach(sortedContractors) { item in
                                Text(item.name).tag(item.name)
                            }
                            if !selectedContractorName.isEmpty,
                               !sortedContractors.contains(where: { $0.name == selectedContractorName }) {
                                Text(selectedContractorName).tag(selectedContractorName)
                            }
                        }
                    }
                    Button("Add contractor") {
                        newContractorName = ""
                        showAddContractor = true
                    }
                } header: {
                    Text("Contractor")
                }
            }
            .navigationTitle("Edit issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { load() }
            .alert("Add discipline", isPresented: $showAddDiscipline) {
                TextField("Name", text: $newDisciplineName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    if let added = store.addDiscipline(name: newDisciplineName) {
                        selectedDisciplineName = added.name
                    }
                }
            } message: {
                Text("Creates a local discipline you can reuse on issues.")
            }
            .alert("Add contractor", isPresented: $showAddContractor) {
                TextField("Name", text: $newContractorName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    if let added = store.addContractor(name: newContractorName) {
                        selectedContractorName = added.name
                    }
                }
            } message: {
                Text("Creates a local contractor you can reuse on issues.")
            }
        }
    }

    private func load() {
        guard let issue = store.issue(id: issueId) else { return }
        title = issue.title
        details = issue.details
        status = issue.status
        selectedDisciplineName = issue.discipline ?? ""
        selectedContractorName = issue.contractor ?? ""
    }

    private func save() {
        store.updateIssueDetails(
            id: issueId,
            title: title,
            details: details,
            status: status,
            discipline: selectedDisciplineName.isEmpty ? nil : selectedDisciplineName,
            contractor: selectedContractorName.isEmpty ? nil : selectedContractorName
        )
        dismiss()
    }
}

#Preview {
    IssueEditor(issueId: UUID())
        .environmentObject(AppStore())
}
