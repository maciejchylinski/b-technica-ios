import SwiftUI

/// Add or edit equipment identity fields. Status changes go through issue / return actions.
struct EquipmentEditor: View {
    @ObservedObject var equipment: EquipmentStore
    /// nil = new item.
    let itemId: UUID?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = ""
    @State private var identifier = ""
    @State private var serialNumber = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    TextField("Category", text: $category)
                        .textInputAutocapitalization(.words)
                    if !equipment.categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(equipment.categories, id: \.self) { value in
                                    Button(value) { category = value }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    TextField("Identifier / asset tag", text: $identifier)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Serial number (optional)", text: $serialNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Examples: Laser level, BT-014, SN 58201-77.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle(itemId == nil ? "New equipment" : "Edit equipment")
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
            .alert("Can't save",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func load() {
        guard let itemId, let item = equipment.item(id: itemId) else { return }
        name = item.item
        category = item.category ?? ""
        identifier = item.identifier ?? ""
        serialNumber = item.serialNumber ?? ""
        notes = item.notes ?? ""
    }

    private func save() {
        let error: String?
        if let itemId {
            error = equipment.update(id: itemId, name: name, category: category, identifier: identifier,
                                     serialNumber: serialNumber, notes: notes)
        } else {
            error = equipment.create(name: name, category: category, identifier: identifier,
                                     serialNumber: serialNumber, notes: notes)
        }
        if let error {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
