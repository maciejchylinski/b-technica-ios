import SwiftUI

/// Simple form for creating (or editing basics of) an issue after the user
/// tapped a point on the PDF.
struct IssueFormView: View {
    @EnvironmentObject private var store: AppStore

    let pageIndex: Int
    let pageCount: Int
    let point: PDFPoint
    var onSave: (String, String, String?, String?) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var details: String = ""
    /// Empty string means "None".
    @State private var selectedDisciplineName: String = ""
    /// Empty string means "None".
    @State private var selectedContractorName: String = ""
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
                } header: {
                    Text("Issue")
                } footer: {
                    if pageCount > 1 {
                        Text("Status defaults to Open. The pin is saved on page \(pageIndex + 1) of the drawing.")
                    } else {
                        Text("Status defaults to Open. The pin is saved on this drawing.")
                    }
                }

                Section {
                    if sortedDisciplines.isEmpty {
                        Text("No disciplines yet.")
                            .foregroundStyle(.secondary)
                        Button("Add discipline") {
                            newDisciplineName = ""
                            showAddDiscipline = true
                        }
                    } else {
                        Picker("Discipline", selection: $selectedDisciplineName) {
                            Text("None").tag("")
                            ForEach(sortedDisciplines) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Add discipline") {
                            newDisciplineName = ""
                            showAddDiscipline = true
                        }
                    }
                } header: {
                    Text("Discipline / category")
                } footer: {
                    Text("Managed under More → Disciplines.")
                }

                Section {
                    if sortedContractors.isEmpty {
                        Text("No contractors yet.")
                            .foregroundStyle(.secondary)
                        Button("Add contractor") {
                            newContractorName = ""
                            showAddContractor = true
                        }
                    } else {
                        Picker("Contractor", selection: $selectedContractorName) {
                            Text("None").tag("")
                            ForEach(sortedContractors) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Add contractor") {
                            newContractorName = ""
                            showAddContractor = true
                        }
                    }
                } header: {
                    Text("Contractor")
                } footer: {
                    Text("Managed under More → Contractors.")
                }
            }
            .navigationTitle("New issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
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

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let discipline = selectedDisciplineName.isEmpty ? nil : selectedDisciplineName
        let contractor = selectedContractorName.isEmpty ? nil : selectedContractorName
        onSave(trimmedTitle, trimmedDetails, discipline, contractor)
    }
}
