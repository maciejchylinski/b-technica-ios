import Foundation

/// Project contact list + user address book, backed by the per-user SQLite database.
/// Local only; not synced to Supabase yet.
@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var companies: [ContactCompany] = []
    @Published private(set) var people: [ContactPerson] = []
    @Published private(set) var links: [ProjectContactLink] = []
    @Published var errorMessage: String?

    let projectId: UUID
    private let database: AppDatabase?

    init(userId: UUID, projectId: UUID) {
        self.projectId = projectId
        do {
            database = try AppDatabase.shared(for: userId)
        } catch {
            database = nil
            errorMessage = "Contacts could not be opened: \(error.localizedDescription)"
        }
        reload()
    }

    func reload() {
        guard let database else { return }
        do {
            companies = try database.fetchContactCompanies()
            people = try database.fetchContactPeople()
            links = try database.fetchProjectContactLinks(projectId: projectId)
        } catch {
            errorMessage = "Contacts could not be loaded: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup

    func company(id: UUID?) -> ContactCompany? {
        guard let id else { return nil }
        return companies.first { $0.id == id }
    }

    func person(id: UUID) -> ContactPerson? {
        people.first { $0.id == id }
    }

    func link(for contact: ContactRef) -> ProjectContactLink? {
        links.first { $0.contact == contact }
    }

    func isInProject(_ contact: ContactRef) -> Bool {
        link(for: contact) != nil
    }

    func exists(_ contact: ContactRef) -> Bool {
        switch contact {
        case .company(let id): return company(id: id) != nil
        case .person(let id): return person(id: id) != nil
        }
    }

    func isInAddressBook(_ contact: ContactRef) -> Bool {
        switch contact {
        case .company(let id): return company(id: id)?.inAddressBook ?? false
        case .person(let id): return person(id: id)?.inAddressBook ?? false
        }
    }

    var projectCompanies: [ContactCompany] {
        companies.filter { isInProject(.company($0.id)) }
    }

    var projectPeople: [ContactPerson] {
        people.filter { isInProject(.person($0.id)) }
    }

    func people(atCompany companyId: UUID) -> [ContactPerson] {
        people.filter { $0.companyId == companyId }
    }

    /// Case/diacritic-insensitive match on name, role, trade/job title, company, phone, email.
    func matches(_ contact: ContactRef, query: String) -> Bool {
        let query = query.trimmed
        guard !query.isEmpty else { return true }
        var fields: [String?]
        switch contact {
        case .company(let id):
            guard let c = company(id: id) else { return false }
            fields = [c.name, c.trade, c.phone, c.email, c.address, c.taxId]
        case .person(let id):
            guard let p = person(id: id) else { return false }
            fields = [p.fullName, p.jobTitle, p.phone, p.email, company(id: p.companyId)?.name]
        }
        fields.append(link(for: contact)?.role)
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }

    /// Number of projects (on this device) the contact belongs to.
    func projectCount(for contact: ContactRef) -> Int {
        guard let database else { return 0 }
        let column: String
        let id: UUID
        switch contact {
        case .company(let value): column = "company_id"; id = value
        case .person(let value): column = "person_id"; id = value
        }
        return (try? database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_contacts WHERE \(column) = ?",
                arguments: [id.uuidString]
            )
        }) ?? 0
    }

    // MARK: - Mutations

    /// Saves a company. When `projectRole` is non-nil the company is linked to this project
    /// (or its existing link's role is updated).
    func saveCompany(_ company: ContactCompany, projectRole: String?) {
        guard let database else { return }
        var company = company
        company.name = company.name.trimmed
        guard !company.name.isEmpty else { return }
        company.trade = company.trade.nilIfBlank
        company.taxId = company.taxId.nilIfBlank
        company.phone = company.phone.nilIfBlank
        company.email = company.email.nilIfBlank
        company.website = company.website.nilIfBlank
        company.address = company.address.nilIfBlank
        company.notes = company.notes.nilIfBlank
        company.updatedDate = Date()
        perform {
            try database.persistContactCompany(
                company,
                link: projectLink(for: .company(company.id), role: projectRole)
            )
        }
    }

    func savePerson(_ person: ContactPerson, projectRole: String?) {
        guard let database else { return }
        var person = person
        person.firstName = person.firstName.trimmed
        person.lastName = person.lastName.trimmed
        guard !person.fullName.isEmpty else { return }
        person.jobTitle = person.jobTitle.nilIfBlank
        person.phone = person.phone.nilIfBlank
        person.email = person.email.nilIfBlank
        person.notes = person.notes.nilIfBlank
        person.updatedDate = Date()
        perform {
            try database.persistContactPerson(
                person,
                link: projectLink(for: .person(person.id), role: projectRole)
            )
        }
    }

    func addToProject(_ contacts: [ContactRef]) {
        guard let database else { return }
        let newLinks = contacts
            .filter { !isInProject($0) }
            .map { ProjectContactLink(projectId: projectId, contact: $0) }
        guard !newLinks.isEmpty else { return }
        perform { try database.persistProjectContactLinks(newLinks) }
    }

    func removeFromProject(_ contact: ContactRef) {
        guard let database else { return }
        perform { try database.removeProjectContact(contact, projectId: projectId) }
    }

    func deleteContact(_ contact: ContactRef) {
        guard let database else { return }
        perform { try database.deleteContact(contact) }
    }

    // MARK: - Private

    private func projectLink(for contact: ContactRef, role: String?) -> ProjectContactLink? {
        guard let role else { return nil }
        var link = link(for: contact) ?? ProjectContactLink(projectId: projectId, contact: contact)
        link.role = role.nilIfBlank
        link.updatedDate = Date()
        return link
    }

    private func perform(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            errorMessage = "Contact could not be saved: \(error.localizedDescription)"
        }
        reload()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : trimmed }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? { self?.nilIfBlank }
}
