import Foundation
import GRDB

extension AppDatabase {
    /// User-owned address book (companies + people) and per-project contact links.
    /// A company or person can be linked to many projects; each link carries a project role.
    static func createProjectContactsSchema(_ db: Database) throws {
        try db.create(table: "contact_companies") { t in
            t.column("id", .text).primaryKey()
            t.column("owner_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("trade", .text)
            t.column("tax_id", .text)
            t.column("phone", .text)
            t.column("email", .text)
            t.column("website", .text)
            t.column("address", .text)
            t.column("notes", .text)
            t.column("in_address_book", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "contact_companies_owner_id", on: "contact_companies", columns: ["owner_id"])

        try db.create(table: "contact_people") { t in
            t.column("id", .text).primaryKey()
            t.column("owner_id", .text).notNull()
            t.column("company_id", .text)
                .references("contact_companies", onDelete: .setNull)
            t.column("first_name", .text).notNull()
            t.column("last_name", .text).notNull().defaults(to: "")
            t.column("job_title", .text)
            t.column("phone", .text)
            t.column("email", .text)
            t.column("notes", .text)
            t.column("in_address_book", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(index: "contact_people_owner_id", on: "contact_people", columns: ["owner_id"])
        try db.create(index: "contact_people_company_id", on: "contact_people", columns: ["company_id"])

        try db.create(table: "project_contacts") { t in
            t.column("id", .text).primaryKey()
            t.column("project_id", .text).notNull()
                .references("projects", onDelete: .cascade)
            t.column("company_id", .text)
                .references("contact_companies", onDelete: .cascade)
            t.column("person_id", .text)
                .references("contact_people", onDelete: .cascade)
            t.column("role", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            // Exactly one of company_id / person_id.
            t.check(sql: "(company_id IS NULL) <> (person_id IS NULL)")
        }
        try db.create(index: "project_contacts_project_id", on: "project_contacts", columns: ["project_id"])
        try db.create(
            index: "project_contacts_project_company",
            on: "project_contacts",
            columns: ["project_id", "company_id"],
            options: .unique,
            condition: Column("company_id") != nil
        )
        try db.create(
            index: "project_contacts_project_person",
            on: "project_contacts",
            columns: ["project_id", "person_id"],
            options: .unique,
            condition: Column("person_id") != nil
        )
        try db.create(index: "project_contacts_company_id", on: "project_contacts", columns: ["company_id"])
        try db.create(index: "project_contacts_person_id", on: "project_contacts", columns: ["person_id"])
    }
}
