import Foundation
import GRDB

/// SQLite read/write for the user-owned address book and per-project contact links.
/// Companies/people are scoped by `owner_id` = authenticated user.
extension AppDatabase {
    func fetchContactCompanies() throws -> [ContactCompany] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, trade, tax_id, phone, email, website, address, notes,
                       in_address_book, created_at, updated_at
                FROM contact_companies
                WHERE owner_id = ?
                ORDER BY name COLLATE NOCASE ASC, created_at ASC
                """,
                arguments: [userId.uuidString]
            )
            return try rows.map { try Self.contactCompany(from: $0) }
        }
    }

    func fetchContactPeople() throws -> [ContactPerson] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, company_id, first_name, last_name, job_title, phone, email, notes,
                       in_address_book, created_at, updated_at
                FROM contact_people
                WHERE owner_id = ?
                ORDER BY last_name COLLATE NOCASE ASC, first_name COLLATE NOCASE ASC
                """,
                arguments: [userId.uuidString]
            )
            return try rows.map { try Self.contactPerson(from: $0) }
        }
    }

    func fetchProjectContactLinks(projectId: UUID) throws -> [ProjectContactLink] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, project_id, company_id, person_id, role, created_at, updated_at
                FROM project_contacts
                WHERE project_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [projectId.uuidString]
            )
            return try rows.map { try Self.projectContactLink(from: $0) }
        }
    }

    /// Upserts a company; when `link` is given, upserts the project link in the same transaction.
    func persistContactCompany(_ company: ContactCompany, link: ProjectContactLink? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO contact_companies
                  (id, owner_id, name, trade, tax_id, phone, email, website, address, notes,
                   in_address_book, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  trade = excluded.trade,
                  tax_id = excluded.tax_id,
                  phone = excluded.phone,
                  email = excluded.email,
                  website = excluded.website,
                  address = excluded.address,
                  notes = excluded.notes,
                  in_address_book = excluded.in_address_book,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    company.id.uuidString,
                    userId.uuidString,
                    company.name,
                    company.trade,
                    company.taxId,
                    company.phone,
                    company.email,
                    company.website,
                    company.address,
                    company.notes,
                    company.inAddressBook,
                    SQLiteDateCoding.string(from: company.createdDate),
                    SQLiteDateCoding.string(from: company.updatedDate)
                ]
            )
            if let link {
                try Self.upsertProjectContactLink(link, db: db)
            }
        }
    }

    /// Upserts a person; when `link` is given, upserts the project link in the same transaction.
    func persistContactPerson(_ person: ContactPerson, link: ProjectContactLink? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO contact_people
                  (id, owner_id, company_id, first_name, last_name, job_title, phone, email, notes,
                   in_address_book, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  company_id = excluded.company_id,
                  first_name = excluded.first_name,
                  last_name = excluded.last_name,
                  job_title = excluded.job_title,
                  phone = excluded.phone,
                  email = excluded.email,
                  notes = excluded.notes,
                  in_address_book = excluded.in_address_book,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    person.id.uuidString,
                    userId.uuidString,
                    person.companyId?.uuidString,
                    person.firstName,
                    person.lastName,
                    person.jobTitle,
                    person.phone,
                    person.email,
                    person.notes,
                    person.inAddressBook,
                    SQLiteDateCoding.string(from: person.createdDate),
                    SQLiteDateCoding.string(from: person.updatedDate)
                ]
            )
            if let link {
                try Self.upsertProjectContactLink(link, db: db)
            }
        }
    }

    func persistProjectContactLinks(_ links: [ProjectContactLink]) throws {
        try dbQueue.write { db in
            for link in links {
                try Self.upsertProjectContactLink(link, db: db)
            }
        }
    }

    /// Removes a contact from a project. Contacts kept out of the address book are deleted
    /// once they are no longer linked to any project.
    func removeProjectContact(_ contact: ContactRef, projectId: UUID) throws {
        try dbQueue.write { db in
            let (table, column, id) = Self.contactColumns(contact)
            try db.execute(
                sql: "DELETE FROM project_contacts WHERE project_id = ? AND \(column) = ?",
                arguments: [projectId.uuidString, id]
            )
            try db.execute(
                sql: """
                DELETE FROM \(table)
                WHERE id = ? AND owner_id = ? AND in_address_book = 0
                  AND NOT EXISTS (SELECT 1 FROM project_contacts WHERE \(column) = ?)
                """,
                arguments: [id, userId.uuidString, id]
            )
        }
    }

    /// Deletes a contact everywhere (address book + all project links via cascade).
    func deleteContact(_ contact: ContactRef) throws {
        try dbQueue.write { db in
            let (table, _, id) = Self.contactColumns(contact)
            try db.execute(
                sql: "DELETE FROM \(table) WHERE id = ? AND owner_id = ?",
                arguments: [id, userId.uuidString]
            )
        }
    }

    // MARK: - Helpers

    private static func contactColumns(_ contact: ContactRef) -> (table: String, linkColumn: String, id: String) {
        switch contact {
        case .company(let id): return ("contact_companies", "company_id", id.uuidString)
        case .person(let id): return ("contact_people", "person_id", id.uuidString)
        }
    }

    private static func upsertProjectContactLink(_ link: ProjectContactLink, db: Database) throws {
        let companyId: String?
        let personId: String?
        switch link.contact {
        case .company(let id): companyId = id.uuidString; personId = nil
        case .person(let id): companyId = nil; personId = id.uuidString
        }
        try db.execute(
            sql: """
            INSERT INTO project_contacts
              (id, project_id, company_id, person_id, role, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              role = excluded.role,
              updated_at = excluded.updated_at
            """,
            arguments: [
                link.id.uuidString,
                link.projectId.uuidString,
                companyId,
                personId,
                link.role,
                SQLiteDateCoding.string(from: link.createdDate),
                SQLiteDateCoding.string(from: link.updatedDate)
            ]
        )
    }

    private static func dates(from row: Row) -> (created: Date, updated: Date) {
        let createdRaw: String = row["created_at"]
        let updatedRaw: String = row["updated_at"]
        let created = SQLiteDateCoding.date(from: createdRaw) ?? Date()
        return (created, SQLiteDateCoding.date(from: updatedRaw) ?? created)
    }

    private static func contactCompany(from row: Row) throws -> ContactCompany {
        guard let id = UUID(uuidString: row["id"]) else {
            throw ContactsMetadataStoreError.invalidRow("contact_companies")
        }
        let (created, updated) = dates(from: row)
        return ContactCompany(
            id: id,
            name: row["name"],
            trade: row["trade"],
            taxId: row["tax_id"],
            phone: row["phone"],
            email: row["email"],
            website: row["website"],
            address: row["address"],
            notes: row["notes"],
            inAddressBook: row["in_address_book"],
            createdDate: created,
            updatedDate: updated
        )
    }

    private static func contactPerson(from row: Row) throws -> ContactPerson {
        guard let id = UUID(uuidString: row["id"]) else {
            throw ContactsMetadataStoreError.invalidRow("contact_people")
        }
        let companyRaw: String? = row["company_id"]
        let (created, updated) = dates(from: row)
        return ContactPerson(
            id: id,
            firstName: row["first_name"],
            lastName: row["last_name"],
            companyId: companyRaw.flatMap(UUID.init(uuidString:)),
            jobTitle: row["job_title"],
            phone: row["phone"],
            email: row["email"],
            notes: row["notes"],
            inAddressBook: row["in_address_book"],
            createdDate: created,
            updatedDate: updated
        )
    }

    private static func projectContactLink(from row: Row) throws -> ProjectContactLink {
        let companyRaw: String? = row["company_id"]
        let personRaw: String? = row["person_id"]
        guard let id = UUID(uuidString: row["id"]),
              let projectId = UUID(uuidString: row["project_id"]) else {
            throw ContactsMetadataStoreError.invalidRow("project_contacts")
        }
        let contact: ContactRef
        if let companyId = companyRaw.flatMap(UUID.init(uuidString:)) {
            contact = .company(companyId)
        } else if let personId = personRaw.flatMap(UUID.init(uuidString:)) {
            contact = .person(personId)
        } else {
            throw ContactsMetadataStoreError.invalidRow("project_contacts")
        }
        let (created, updated) = dates(from: row)
        return ProjectContactLink(
            id: id,
            projectId: projectId,
            contact: contact,
            role: row["role"],
            createdDate: created,
            updatedDate: updated
        )
    }
}

enum ContactsMetadataStoreError: LocalizedError {
    case invalidRow(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let table):
            return "Invalid SQLite row in \(table)"
        }
    }
}
