import SwiftUI

/// Create or edit a company. New companies are added to the current project by default.
struct CompanyEditorSheet: View {
    @ObservedObject var contacts: ContactsStore
    let company: ContactCompany?

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ContactCompany(name: "")
    @State private var inProject = true
    @State private var role = ""

    private var isLinked: Bool {
        company.map { contacts.isInProject(.company($0.id)) } ?? false
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (inProject || draft.inAddressBook)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Company name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                    OptionalTextField("Trade / type (optional)", text: $draft.trade)
                        .textInputAutocapitalization(.words)
                }

                Section("Contact") {
                    OptionalTextField("Phone", text: $draft.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    OptionalTextField("Email", text: $draft.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    OptionalTextField("Website", text: $draft.website)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    OptionalTextField("Address", text: $draft.address, axis: .vertical)
                        .lineLimit(1...3)
                    OptionalTextField("Tax ID", text: $draft.taxId)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                ProjectRoleSection(isLinked: isLinked, inProject: $inProject, role: $role)

                AddressBookSection(inAddressBook: $draft.inAddressBook, inProject: inProject, noun: "company")

                Section("Notes") {
                    OptionalTextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(company == nil ? "New company" : "Edit company")
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
                if let company {
                    draft = company
                    inProject = isLinked
                    role = contacts.link(for: .company(company.id))?.role ?? ""
                }
            }
        }
    }

    private func save() {
        contacts.saveCompany(draft, projectRole: inProject ? role : nil)
        dismiss()
    }
}

/// Create or edit a person. `companyId` pre-selects the employer for new people.
struct PersonEditorSheet: View {
    @ObservedObject var contacts: ContactsStore
    let person: ContactPerson?
    var companyId: UUID?

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ContactPerson(firstName: "")
    @State private var inProject = true
    @State private var role = ""

    private var isLinked: Bool {
        person.map { contacts.isInProject(.person($0.id)) } ?? false
    }

    private var canSave: Bool {
        !(draft.firstName + draft.lastName).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (inProject || draft.inAddressBook)
    }

    /// Companies in the address book or this project, plus the current employer.
    private var companyOptions: [ContactCompany] {
        contacts.companies.filter {
            $0.inAddressBook || contacts.isInProject(.company($0.id)) || $0.id == draft.companyId
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $draft.firstName)
                        .textInputAutocapitalization(.words)
                        .textContentType(.givenName)
                    TextField("Last name", text: $draft.lastName)
                        .textInputAutocapitalization(.words)
                        .textContentType(.familyName)
                    OptionalTextField("Job title (optional)", text: $draft.jobTitle)
                        .textInputAutocapitalization(.words)
                    Picker("Company", selection: $draft.companyId) {
                        Text("None").tag(UUID?.none)
                        ForEach(companyOptions) { company in
                            Text(company.name).tag(UUID?.some(company.id))
                        }
                    }
                }

                Section("Contact") {
                    OptionalTextField("Phone", text: $draft.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    OptionalTextField("Email", text: $draft.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                ProjectRoleSection(isLinked: isLinked, inProject: $inProject, role: $role)

                AddressBookSection(inAddressBook: $draft.inAddressBook, inProject: inProject, noun: "person")

                Section("Notes") {
                    OptionalTextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(person == nil ? "New person" : "Edit person")
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
                if let person {
                    draft = person
                    inProject = isLinked
                    role = contacts.link(for: .person(person.id))?.role ?? ""
                } else {
                    draft.companyId = companyId
                }
            }
        }
    }

    private func save() {
        contacts.savePerson(draft, projectRole: inProject ? role : nil)
        dismiss()
    }
}

// MARK: - Shared sections

private struct ProjectRoleSection: View {
    let isLinked: Bool
    @Binding var inProject: Bool
    @Binding var role: String

    var body: some View {
        Section {
            if !isLinked {
                Toggle("Add to this project", isOn: $inProject)
            }
            if inProject {
                TextField("Role in project (e.g. Site manager)", text: $role)
                    .textInputAutocapitalization(.sentences)
            }
        } header: {
            Text("This project")
        }
    }
}

private struct AddressBookSection: View {
    @Binding var inAddressBook: Bool
    let inProject: Bool
    let noun: String

    var body: some View {
        Section {
            Toggle("Show in address book", isOn: $inAddressBook)
        } footer: {
            if !inAddressBook && !inProject {
                Text("Add this \(noun) to the project or keep it in the address book.")
                    .foregroundStyle(.red)
            } else {
                Text("Address book contacts can be added to your other projects.")
            }
        }
    }
}

/// `TextField` bound to an optional string (empty text ⇄ nil).
private struct OptionalTextField: View {
    let title: String
    @Binding var text: String?
    var axis: Axis = .horizontal

    init(_ title: String, text: Binding<String?>, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField(
            title,
            text: Binding(get: { text ?? "" }, set: { text = $0.isEmpty ? nil : $0 }),
            axis: axis
        )
    }
}
