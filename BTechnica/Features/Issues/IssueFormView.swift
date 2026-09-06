import SwiftUI

/// Simple form for creating (or editing basics of) an issue after the user
/// tapped a point on the PDF.
struct IssueFormView: View {
    let pageIndex: Int
    let point: PDFPoint
    var onSave: (String, String, String?, String?) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var details: String = ""
    @State private var discipline: String = ""
    @State private var contractor: String = ""

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    Text("Status defaults to Open. The pin is saved on page \(pageIndex + 1) of the drawing.")
                }

                Section("Optional") {
                    TextField("Discipline / category", text: $discipline)
                        .textInputAutocapitalization(.words)
                    TextField("Contractor", text: $contractor)
                        .textInputAutocapitalization(.words)
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
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDiscipline = discipline.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContractor = contractor.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(
            trimmedTitle,
            trimmedDetails,
            trimmedDiscipline.isEmpty ? nil : trimmedDiscipline,
            trimmedContractor.isEmpty ? nil : trimmedContractor
        )
    }
}
