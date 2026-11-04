import SwiftUI

/// Multi-select picker for adding existing address book contacts to the current project.
struct AddressBookPickerView: View {
    @ObservedObject var contacts: ContactsStore

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selection: Set<ContactRef> = []

    private var availableCompanies: [ContactCompany] {
        contacts.companies.filter {
            $0.inAddressBook && !contacts.isInProject(.company($0.id))
        }
    }

    private var availablePeople: [ContactPerson] {
        contacts.people.filter {
            $0.inAddressBook && !contacts.isInProject(.person($0.id))
        }
    }

    private var visibleCompanies: [ContactCompany] {
        availableCompanies.filter { contacts.matches(.company($0.id), query: searchText) }
    }

    private var visiblePeople: [ContactPerson] {
        availablePeople.filter { contacts.matches(.person($0.id), query: searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableCompanies.isEmpty && availablePeople.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to add", systemImage: "book.closed")
                    } description: {
                        Text("Every address book contact is already in this project, or the address book is empty.")
                    }
                } else {
                    List {
                        if !visibleCompanies.isEmpty {
                            Section("Companies") {
                                ForEach(visibleCompanies) { company in
                                    row(.company(company.id),
                                        title: company.name,
                                        subtitle: company.trade,
                                        systemImage: "building.2")
                                }
                            }
                        }
                        if !visiblePeople.isEmpty {
                            Section("People") {
                                ForEach(visiblePeople) { person in
                                    row(.person(person.id),
                                        title: person.fullName,
                                        subtitle: [person.jobTitle, contacts.company(id: person.companyId)?.name]
                                            .compactMap { $0 }
                                            .joined(separator: " · "),
                                        systemImage: "person.crop.circle")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search address book")
                    .overlay {
                        if visibleCompanies.isEmpty && visiblePeople.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
            .navigationTitle("Address book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add (\(selection.count))") {
                        contacts.addToProject(Array(selection))
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ ref: ContactRef, title: String, subtitle: String?, systemImage: String) -> some View {
        let isSelected = selection.contains(ref)
        return Button {
            if isSelected { selection.remove(ref) } else { selection.insert(ref) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Theme.blue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.blue : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
