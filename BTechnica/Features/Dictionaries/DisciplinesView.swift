import SwiftUI

/// Local discipline / category dictionary: list, add, edit, and safe delete.
struct DisciplinesView: View {
    @EnvironmentObject private var store: AppStore

    @State private var editor: DisciplineEditor?
    @State private var deleteBlockedMessage: String?

    private var sorted: [Discipline] {
        store.data.disciplines.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if sorted.isEmpty {
                ContentUnavailableView {
                    Label("No disciplines yet", systemImage: "tag")
                } description: {
                    Text("Add disciplines or categories here so they can be selected when creating issues.")
                } actions: {
                    Button("Add discipline") {
                        editor = .add
                    }
                }
            } else {
                List {
                    ForEach(sorted) { discipline in
                        Button {
                            editor = .edit(discipline)
                        } label: {
                            Text(discipline.name)
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Disciplines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add discipline")
            }
        }
        .sheet(item: $editor) { mode in
            DisciplineEditorSheet(mode: mode)
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
            let discipline = sorted[index]
            if let reason = store.deleteDiscipline(discipline) {
                deleteBlockedMessage = reason
            }
        }
    }
}

private enum DisciplineEditor: Identifiable {
    case add
    case edit(Discipline)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let d): return d.id.uuidString
        }
    }
}

private struct DisciplineEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let mode: DisciplineEditor

    @State private var name: String = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        switch mode {
        case .add: return "New discipline"
        case .edit: return "Edit discipline"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Examples: Electrical, HVAC, Architectural.")
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
                if case .edit(let discipline) = mode {
                    name = discipline.name
                }
            }
        }
    }

    private func save() {
        switch mode {
        case .add:
            _ = store.addDiscipline(name: name)
        case .edit(var discipline):
            discipline.name = name
            store.updateDiscipline(discipline)
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        DisciplinesView()
            .environmentObject(AppStore())
    }
}
