import SwiftUI

struct CompanyDetailView: View {
    @ObservedObject var contacts: ContactsStore
    let companyId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var editing: ContactEditTarget?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let company = contacts.company(id: companyId) {
                content(company)
            } else {
                ContentUnavailableView("Contact deleted", systemImage: "building.2")
            }
        }
        .navigationTitle("Company")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            switch target {
            case .company(let company):
                CompanyEditorSheet(contacts: contacts, company: company)
            case .newPerson(let companyId):
                PersonEditorSheet(contacts: contacts, person: nil, companyId: companyId)
            case .person:
                EmptyView()
            }
        }
    }

    private func content(_ company: ContactCompany) -> some View {
        let ref = ContactRef.company(company.id)
        let staff = contacts.people(atCompany: company.id)
        return List {
            Section {
                ContactHeader(title: company.name, subtitle: company.trade, systemImage: "building.2")
                ContactQuickActions(phone: company.phone, email: company.email, website: company.website)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            ProjectMembershipSection(contacts: contacts, contact: ref)

            Section("Details") {
                ContactValueRow(label: "Phone", value: company.phone, url: ContactURL.phone(company.phone))
                ContactValueRow(label: "Email", value: company.email, url: ContactURL.email(company.email))
                ContactValueRow(label: "Website", value: company.website, url: ContactURL.website(company.website))
                ContactValueRow(label: "Address", value: company.address, url: nil)
                ContactValueRow(label: "Tax ID", value: company.taxId, url: nil)
            }

            Section {
                ForEach(staff) { person in
                    NavigationLink {
                        PersonDetailView(contacts: contacts, personId: person.id)
                    } label: {
                        ContactRow(
                            title: person.fullName,
                            subtitle: person.jobTitle,
                            systemImage: "person.crop.circle",
                            phone: person.phone,
                            email: person.email
                        )
                    }
                }
                Button {
                    editing = .newPerson(companyId: company.id)
                } label: {
                    Label("Add person", systemImage: "person.badge.plus")
                }
            } header: {
                Text("People")
            }

            if let notes = company.notes {
                Section("Notes") { Text(notes) }
            }

            ContactDangerSection(
                contacts: contacts,
                contact: ref,
                name: company.name,
                confirmDelete: $confirmDelete,
                onDeleted: { dismiss() }
            )
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = .company(company) }
            }
        }
    }
}

struct PersonDetailView: View {
    @ObservedObject var contacts: ContactsStore
    let personId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var editing: ContactEditTarget?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let person = contacts.person(id: personId) {
                content(person)
            } else {
                ContentUnavailableView("Contact deleted", systemImage: "person.crop.circle")
            }
        }
        .navigationTitle("Person")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            if case .person(let person) = target {
                PersonEditorSheet(contacts: contacts, person: person)
            }
        }
    }

    private func content(_ person: ContactPerson) -> some View {
        let ref = ContactRef.person(person.id)
        let company = contacts.company(id: person.companyId)
        return List {
            Section {
                ContactHeader(
                    title: person.fullName,
                    subtitle: [person.jobTitle, company?.name].compactMap { $0 }.joined(separator: " · "),
                    systemImage: "person.crop.circle"
                )
                ContactQuickActions(phone: person.phone, email: person.email, website: nil)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            ProjectMembershipSection(contacts: contacts, contact: ref)

            Section("Details") {
                ContactValueRow(label: "Phone", value: person.phone, url: ContactURL.phone(person.phone))
                ContactValueRow(label: "Email", value: person.email, url: ContactURL.email(person.email))
                ContactValueRow(label: "Job title", value: person.jobTitle, url: nil)
                if let company {
                    NavigationLink {
                        CompanyDetailView(contacts: contacts, companyId: company.id)
                    } label: {
                        LabeledContent("Company", value: company.name)
                    }
                }
            }

            if let notes = person.notes {
                Section("Notes") { Text(notes) }
            }

            ContactDangerSection(
                contacts: contacts,
                contact: ref,
                name: person.fullName,
                confirmDelete: $confirmDelete,
                onDeleted: { dismiss() }
            )
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = .person(person) }
            }
        }
    }
}

private enum ContactEditTarget: Identifiable {
    case company(ContactCompany)
    case person(ContactPerson)
    case newPerson(companyId: UUID)

    var id: String {
        switch self {
        case .company(let c): return "company-\(c.id.uuidString)"
        case .person(let p): return "person-\(p.id.uuidString)"
        case .newPerson(let companyId): return "new-person-\(companyId.uuidString)"
        }
    }
}

// MARK: - Shared pieces

private struct ContactHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(Theme.blue)
                .frame(width: 72, height: 72)
                .background(Theme.blue.opacity(0.12), in: Circle())
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Large call / message / email / web buttons; disabled when the value is missing.
private struct ContactQuickActions: View {
    let phone: String?
    let email: String?
    let website: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            action("Call", systemImage: "phone.fill", url: ContactURL.phone(phone))
            action("Message", systemImage: "message.fill", url: ContactURL.message(phone))
            action("Email", systemImage: "envelope.fill", url: ContactURL.email(email))
            if website != nil {
                action("Web", systemImage: "safari.fill", url: ContactURL.website(website))
            }
        }
    }

    private func action(_ title: String, systemImage: String, url: URL?) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: Theme.touchTarget + 12)
            .foregroundStyle(url == nil ? Color.secondary : Theme.blue)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.borderless)
        .disabled(url == nil)
    }
}

private struct ContactValueRow: View {
    let label: String
    let value: String?
    let url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let value {
            if let url {
                Button {
                    openURL(url)
                } label: {
                    LabeledContent(label) {
                        Text(value).foregroundStyle(Theme.blue)
                    }
                }
                .foregroundStyle(.primary)
                .contextMenu {
                    Button("Copy") { UIPasteboard.general.string = value }
                }
            } else {
                LabeledContent(label, value: value)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Role in the current project, or a button to add the contact to it.
private struct ProjectMembershipSection: View {
    @ObservedObject var contacts: ContactsStore
    let contact: ContactRef

    var body: some View {
        Section {
            if let link = contacts.link(for: contact) {
                LabeledContent("Role", value: link.role ?? "Not set")
            } else {
                Button {
                    contacts.addToProject([contact])
                } label: {
                    Label("Add to this project", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("This project")
        } footer: {
            let count = contacts.projectCount(for: contact)
            Text(count == 1 ? "Linked to 1 project." : "Linked to \(count) projects.")
        }
    }
}

private struct ContactDangerSection: View {
    @ObservedObject var contacts: ContactsStore
    let contact: ContactRef
    let name: String
    @Binding var confirmDelete: Bool
    let onDeleted: () -> Void

    var body: some View {
        Section {
            if contacts.isInProject(contact) {
                Button("Remove from project", role: .destructive) {
                    contacts.removeFromProject(contact)
                    if !contacts.exists(contact) { onDeleted() }
                }
            }
            Button("Delete contact", role: .destructive) {
                confirmDelete = true
            }
            .confirmationDialog(
                "Delete \(name)?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete from all projects", role: .destructive) {
                    contacts.deleteContact(contact)
                    onDeleted()
                }
            } message: {
                Text("The contact is removed from the address book and every project.")
            }
        } footer: {
            if contacts.isInAddressBook(contact) {
                Text("Removing from the project keeps the contact in your address book.")
            } else {
                Text("This contact is not in your address book; removing it from its last project deletes it.")
            }
        }
    }
}
