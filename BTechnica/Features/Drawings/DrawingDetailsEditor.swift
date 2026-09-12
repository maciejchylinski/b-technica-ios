import SwiftUI

/// Shared form for entering or editing drawing metadata after import, from the
/// drawings list, or from the drawing viewer overflow menu.
struct DrawingDetailsEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let drawingId: UUID

    @State private var name: String = ""
    @State private var revision: String = ""
    @State private var disciplineName: String = ""
    @State private var location: String = ""
    @State private var hasDrawingDate = false
    @State private var drawingDate = Date()
    @State private var showAddDiscipline = false
    @State private var newDisciplineName = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedDisciplines: [Discipline] {
        store.data.disciplines.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Drawing name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Required. Usually the title on the sheet.")
                }

                Section {
                    TextField("Revision", text: $revision)
                        .textInputAutocapitalization(.never)
                    TextField("Level / location", text: $location)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Optional. Examples: revision C, Level 2.")
                }

                Section {
                    if sortedDisciplines.isEmpty && disciplineName.isEmpty {
                        Text("No disciplines yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Discipline / type", selection: $disciplineName) {
                            Text("None").tag("")
                            ForEach(sortedDisciplines) { item in
                                Text(item.name).tag(item.name)
                            }
                            if !disciplineName.isEmpty,
                               !sortedDisciplines.contains(where: { $0.name == disciplineName }) {
                                Text(disciplineName).tag(disciplineName)
                            }
                        }
                    }
                    Button("Add discipline") {
                        newDisciplineName = ""
                        showAddDiscipline = true
                    }
                } header: {
                    Text("Discipline / type")
                } footer: {
                    Text("Optional. Uses the same local list as issues (More → Disciplines).")
                }

                Section {
                    Toggle("Drawing date", isOn: $hasDrawingDate)
                    if hasDrawingDate {
                        DatePicker("Date",
                                   selection: $drawingDate,
                                   displayedComponents: .date)
                    }
                } footer: {
                    Text("Optional. The date printed on the drawing, if you want to record it.")
                }
            }
            .navigationTitle("Drawing details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
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
                        disciplineName = added.name
                    }
                }
            } message: {
                Text("Creates a local discipline you can reuse on drawings and issues.")
            }
        }
    }

    private func load() {
        guard let drawing = store.data.drawings.first(where: { $0.id == drawingId }) else { return }
        name = drawing.name
        revision = drawing.revision ?? ""
        disciplineName = drawing.discipline ?? ""
        location = drawing.location ?? ""
        if let date = drawing.drawingDate {
            hasDrawingDate = true
            drawingDate = date
        } else {
            hasDrawingDate = false
            drawingDate = Date()
        }
    }

    private func save() {
        store.updateDrawingDetails(
            id: drawingId,
            name: name,
            revision: revision,
            discipline: disciplineName,
            location: location,
            drawingDate: hasDrawingDate ? drawingDate : nil
        )
        finish()
    }

    private func finish() {
        dismiss()
    }
}

#Preview {
    DrawingDetailsEditor(drawingId: UUID())
        .environmentObject(AppStore())
}
