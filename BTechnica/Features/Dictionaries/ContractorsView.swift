import SwiftUI

/// Local contractor dictionary: list, add, edit, and safe delete.
struct ContractorsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var editor: DictionaryEditor?
    @State private var deleteBlockedMessage: String?

    private var sorted: [Contractor] {
        store.data.contractors.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if sorted.isEmpty {
                ContentUnavailableView {
                    Label("No contractors yet", systemImage: "person.2")
                } description: {
                    Text("Add contractors here so they can be selected when creating issues.")
                } actions: {
                    Button("Add contractor") {
                        editor = .add
                    }
                }
            } else {
                List {
                    ForEach(sorted) { contractor in
                        Button {
                            editor = .editContractor(contractor)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(contractor.name)
                                    .foregroundStyle(.primary)
                                if let notes = contractor.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Contractors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add contractor")
            }
        }
        .sheet(item: $editor) { mode in
            ContractorEditorSheet(mode: mode)
                .environmentObject(store)
        }
        .alert("Can't delete",
               isPresented: Binding(get: { deleteBlockedMessage != nil },
                                    set: { if !$0 { deleteBlockedMessage = nil } })) {
            Button("OK", role: .cancel) { deleteBlockedMessage = nil }
        } message: {
            Text(deleteBlockedMessage ?? "")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let contractor = sorted[index]
            if let reason = store.deleteContractor(contractor) {
                deleteBlockedMessage = reason
            }
        }
    }
}

private enum DictionaryEditor: Identifiable {
    case add
    case editContractor(Contractor)

    var id: String {
        switch self {
        case .add: return "add"
        case .editContractor(let c): return c.id.uuidString
        }
    }
}

private struct ContractorEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let mode: DictionaryEditor

    @State private var name: String = ""
    @State private var notes: String = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        switch mode {
        case .add: return "New contractor"
        case .editContractor: return "Edit contractor"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Trade / notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.sentences)
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
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if case .editContractor(let contractor) = mode {
                    name = contractor.name
                    notes = contractor.notes ?? ""
                }
            }
        }
    }

    private func save() {
        switch mode {
        case .add:
            _ = store.addContractor(name: name, notes: notes)
        case .editContractor(var contractor):
            contractor.name = name
            contractor.notes = notes
            store.updateContractor(contractor)
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        ContractorsView()
            .environmentObject(AppStore())
    }
}
