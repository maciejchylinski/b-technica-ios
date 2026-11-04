import Foundation

/// A company in the user's address book (contractor, supplier, client, designer…).
/// Owned by the user; linked to projects through `ProjectContactLink`.
struct ContactCompany: Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// Trade or company type (e.g. "Electrical", "General contractor").
    var trade: String?
    var taxId: String?
    var phone: String?
    var email: String?
    var website: String?
    var address: String?
    var notes: String?
    /// When false the company exists only for the projects it is linked to
    /// and is hidden from the address book picker.
    var inAddressBook: Bool
    var createdDate: Date
    var updatedDate: Date

    init(id: UUID = UUID(),
         name: String,
         trade: String? = nil,
         taxId: String? = nil,
         phone: String? = nil,
         email: String? = nil,
         website: String? = nil,
         address: String? = nil,
         notes: String? = nil,
         inAddressBook: Bool = true,
         createdDate: Date = Date(),
         updatedDate: Date = Date()) {
        self.id = id
        self.name = name
        self.trade = trade
        self.taxId = taxId
        self.phone = phone
        self.email = email
        self.website = website
        self.address = address
        self.notes = notes
        self.inAddressBook = inAddressBook
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }
}

/// An individual contact, optionally employed by a `ContactCompany`.
struct ContactPerson: Identifiable, Equatable, Hashable {
    var id: UUID
    var firstName: String
    var lastName: String
    var companyId: UUID?
    var jobTitle: String?
    var phone: String?
    var email: String?
    var notes: String?
    var inAddressBook: Bool
    var createdDate: Date
    var updatedDate: Date

    init(id: UUID = UUID(),
         firstName: String,
         lastName: String = "",
         companyId: UUID? = nil,
         jobTitle: String? = nil,
         phone: String? = nil,
         email: String? = nil,
         notes: String? = nil,
         inAddressBook: Bool = true,
         createdDate: Date = Date(),
         updatedDate: Date = Date()) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.companyId = companyId
        self.jobTitle = jobTitle
        self.phone = phone
        self.email = email
        self.notes = notes
        self.inAddressBook = inAddressBook
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    var fullName: String {
        [firstName, lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Identifies either a company or a person.
enum ContactRef: Hashable, Identifiable {
    case company(UUID)
    case person(UUID)

    var id: String {
        switch self {
        case .company(let id): return "company-\(id.uuidString)"
        case .person(let id): return "person-\(id.uuidString)"
        }
    }
}

/// Membership of a company or person in a project's contact list.
struct ProjectContactLink: Identifiable, Equatable, Hashable {
    var id: UUID
    var projectId: UUID
    var contact: ContactRef
    /// Project-specific role (e.g. "Site manager", "MEP subcontractor").
    var role: String?
    var createdDate: Date
    var updatedDate: Date

    init(id: UUID = UUID(),
         projectId: UUID,
         contact: ContactRef,
         role: String? = nil,
         createdDate: Date = Date(),
         updatedDate: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.contact = contact
        self.role = role
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }
}
