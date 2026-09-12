import SwiftUI

/// Add or edit equipment identity fields (name, category, identifier, notes).
struct EquipmentEditor: View {
    enum Mode: Identifiable {
        case add
        case edit(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return id.uuidString
            }
        }
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var category = ""
    @State private var identifier = ""
    @State private var notes = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        switch mode {
        case .add: return "New equipment"
        case .edit: return "Edit equipment"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Required. What the item is called on site.")
                }

                Section {
                    TextField("Type / category", text: $category)
                        .textInputAutocapitalization(.words)
                    TextField("Identifier / serial", text: $identifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Optional. Examples: Laser level, SN-1042.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
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
            .onAppear { load() }
        }
    }

    private func load() {
        guard case .edit(let id) = mode,
              let item = store.equipment(id: id) else { return }
        name = item.item
        category = item.category ?? ""
        identifier = item.identifier ?? ""
        notes = item.notes ?? ""
    }

    private func save() {
        switch mode {
        case .add:
            _ = store.addEquipment(
                name: name,
                category: category,
                identifier: identifier,
                notes: notes
            )
        case .edit(let id):
            store.updateEquipmentDetails(
                id: id,
                name: name,
                category: category,
                identifier: identifier,
                notes: notes
            )
        }
        dismiss()
    }
}

#Preview {
    EquipmentEditor(mode: .add)
        .environmentObject(AppStore())
}
