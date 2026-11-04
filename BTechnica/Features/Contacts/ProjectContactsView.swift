import SwiftUI

/// Project contact list: companies and people linked to the current project, with search
/// and quick call/email actions. Contacts live in the user's address book and can be
/// reused across projects.
struct ProjectContactsView: View {
    @StateObject private var contacts: ContactsStore

    @State private var searchText = ""
    @State private var filter: ContactFilter = .all
    @State private var sheet: ContactListSheet?

    init(userId: UUID, projectId: UUID) {
        _contacts = StateObject(wrappedValue: ContactsStore(userId: userId, projectId: projectId))
    }

    private var visibleCompanies: [ContactCompany] {
        guard filter != .people else { return [] }
        return contacts.projectCompanies.filter { contacts.matches(.company($0.id), query: searchText) }
    }

    private var visiblePeople: [ContactPerson] {
        guard filter != .companies else { return [] }
        return contacts.projectPeople.filter { contacts.matches(.person($0.id), query: searchText) }
    }

    private var isProjectEmpty: Bool {
        contacts.links.isEmpty
    }

    var body: some View {
        Group {
            if isProjectEmpty {
                ContentUnavailableView {
                    Label("No project contacts", systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text("Add the companies and people working on this project.")
                } actions: {
                    Button("New company") { sheet = .newCompany }
                    Button("New person") { sheet = .newPerson }
                    Button("Add from address book") { sheet = .addressBook }
                }
            } else {
                List {
                    Section {
                        Picker("Show", selection: $filter) {
                            ForEach(ContactFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }

                    if !visibleCompanies.isEmpty {
                        Section("Companies") {
                            ForEach(visibleCompanies) { company in
                                NavigationLink {
                                    CompanyDetailView(contacts: contacts, companyId: company.id)
                                } label: {
                                    ContactRow(
                                        title: company.name,
                                        subtitle: subtitle(for: company),
                                        systemImage: "building.2",
                                        phone: company.phone,
                                        email: company.email
                                    )
                                }
                                .swipeActions {
                                    removeButton(.company(company.id))
                                }
                            }
                        }
                    }

                    if !visiblePeople.isEmpty {
                        Section("People") {
                            ForEach(visiblePeople) { person in
                                NavigationLink {
                                    PersonDetailView(contacts: contacts, personId: person.id)
                                } label: {
                                    ContactRow(
                                        title: person.fullName,
                                        subtitle: subtitle(for: person),
                                        systemImage: "person.crop.circle",
                                        phone: person.phone,
                                        email: person.email
                                    )
                                }
                                .swipeActions {
                                    removeButton(.person(person.id))
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "Name, role, company, phone")
                .overlay {
                    if visibleCompanies.isEmpty && visiblePeople.isEmpty {
                        if searchText.isEmpty {
                            ContentUnavailableView(
                                filter == .companies ? "No companies" : "No people",
                                systemImage: filter == .companies ? "building.2" : "person.crop.circle"
                            )
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { sheet = .newCompany } label: {
                        Label("New company", systemImage: "building.2")
                    }
                    Button { sheet = .newPerson } label: {
                        Label("New person", systemImage: "person.badge.plus")
                    }
                    Divider()
                    Button { sheet = .addressBook } label: {
                        Label("Add from address book", systemImage: "book.closed")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add contact")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newCompany:
                CompanyEditorSheet(contacts: contacts, company: nil)
            case .newPerson:
                PersonEditorSheet(contacts: contacts, person: nil)
            case .addressBook:
                AddressBookPickerView(contacts: contacts)
            }
        }
        .alert("Contacts",
               isPresented: Binding(get: { contacts.errorMessage != nil },
                                    set: { if !$0 { contacts.errorMessage = nil } })) {
            Button("OK", role: .cancel) { contacts.errorMessage = nil }
        } message: {
            Text(contacts.errorMessage ?? "")
        }
    }

    private func subtitle(for company: ContactCompany) -> String? {
        [contacts.link(for: .company(company.id))?.role, company.trade]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private func subtitle(for person: ContactPerson) -> String? {
        [contacts.link(for: .person(person.id))?.role ?? person.jobTitle,
         contacts.company(id: person.companyId)?.name]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private func removeButton(_ contact: ContactRef) -> some View {
        Button(role: .destructive) {
            contacts.removeFromProject(contact)
        } label: {
            Label("Remove", systemImage: "minus.circle")
        }
    }
}

private enum ContactFilter: String, CaseIterable, Identifiable {
    case all, companies, people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .companies: return "Companies"
        case .people: return "People"
        }
    }
}

private enum ContactListSheet: String, Identifiable {
    case newCompany, newPerson, addressBook

    var id: String { rawValue }
}

/// List row with leading icon, name/subtitle, and trailing call/email buttons.
struct ContactRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let phone: String?
    let email: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = ContactURL.phone(phone) {
                quickButton("phone.fill", label: "Call \(title)") { openURL(url) }
            }
            if let url = ContactURL.email(email) {
                quickButton("envelope.fill", label: "Email \(title)") { openURL(url) }
            }
        }
        .padding(.vertical, 2)
    }

    private func quickButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.blue)
                .frame(width: 40, height: 40)
                .background(Theme.blue.opacity(0.12), in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// `tel:` / `sms:` / `mailto:` / web URLs from free-text contact fields.
enum ContactURL {
    static func phone(_ raw: String?) -> URL? {
        dialable(raw).flatMap { URL(string: "tel:\($0)") }
    }

    static func message(_ raw: String?) -> URL? {
        dialable(raw).flatMap { URL(string: "sms:\($0)") }
    }

    static func email(_ raw: String?) -> URL? {
        guard let address = raw?.trimmingCharacters(in: .whitespaces), address.contains("@"),
              let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) else {
            return nil
        }
        return URL(string: "mailto:\(encoded)")
    }

    static func website(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let withScheme = value.contains("://") ? value : "https://\(value)"
        return URL(string: withScheme)
    }

    private static func dialable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : digits
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
