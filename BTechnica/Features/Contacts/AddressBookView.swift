import SwiftUI

/// The user's global address book: every company and person across projects on this device.
/// Opening a contact shows its role in the current project, with an option to add it.
struct AddressBookView: View {
    @ObservedObject var contacts: ContactsStore
    @EnvironmentObject private var store: AppStore

    @State private var searchText = ""
    @State private var pendingDelete: (ref: ContactRef, name: String)?
    @State private var importResult: String?

    private var companies: [ContactCompany] {
        contacts.companies.filter { $0.inAddressBook && contacts.matches(.company($0.id), query: searchText) }
    }

    private var people: [ContactPerson] {
        contacts.people.filter { $0.inAddressBook && contacts.matches(.person($0.id), query: searchText) }
    }

    private var importableContractors: [Contractor] {
        contacts.contractorsNotInAddressBook(store.data.contractors)
    }

    var body: some View {
        List {
            if !importableContractors.isEmpty {
                Section {
                    Button {
                        let count = contacts.importContractors(store.data.contractors, addToProject: false)
                        importResult = count == 1 ? "1 contractor added." : "\(count) contractors added."
                    } label: {
                        Label("Import \(importableContractors.count) from Contractors", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("Copies your contractor dictionary into the address book as companies. The dictionary used by issues is unchanged.")
                }
            }

            if !companies.isEmpty {
                Section("Companies") {
                    ForEach(companies) { company in
                        NavigationLink {
                            CompanyDetailView(contacts: contacts, companyId: company.id)
                        } label: {
                            ContactRow(
                                title: company.name,
                                subtitle: projectSummary(.company(company.id), detail: company.trade),
                                systemImage: "building.2",
                                phone: company.phone,
                                email: company.email
                            )
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDelete = (.company(company.id), company.name)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonDetailView(contacts: contacts, personId: person.id)
                        } label: {
                            ContactRow(
                                title: person.fullName,
                                subtitle: projectSummary(.person(person.id),
                                                         detail: contacts.company(id: person.companyId)?.name),
                                systemImage: "person.crop.circle",
                                phone: person.phone,
                                email: person.email
                            )
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDelete = (.person(person.id), person.fullName)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search address book")
        .overlay {
            if companies.isEmpty && people.isEmpty && importableContractors.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("Address book is empty", systemImage: "book.closed",
                                           description: Text("Contacts you create in any project appear here."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle("Address book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { contacts.reload() }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "contact")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from all projects", role: .destructive) {
                if let pendingDelete { contacts.deleteContact(pendingDelete.ref) }
                pendingDelete = nil
            }
        } message: {
            Text("The contact is removed from the address book and every project. Equipment history keeps the name.")
        }
        .alert("Contractors imported",
               isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResult ?? "")
        }
    }

    private func projectSummary(_ ref: ContactRef, detail: String?) -> String {
        let count = contacts.projectCount(for: ref)
        let projects = contacts.isInProject(ref)
            ? "In this project"
            : (count == 0 ? "No projects" : (count == 1 ? "1 project" : "\(count) projects"))
        return [detail, projects].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Equipment currently held by a contact (any project); shown on contact detail screens.
struct HeldEquipmentSection: View {
    @ObservedObject var contacts: ContactsStore
    let contact: ContactRef

    @State private var held: [AppDatabase.HeldEquipment] = []

    var body: some View {
        Group {
            if !held.isEmpty {
                Section("Holds equipment") {
                    ForEach(held) { entry in
                        LabeledContent(entry.itemName) {
                            Text("since \(entry.checkout.issuedDate.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
            }
        }
        .onAppear { held = contacts.heldEquipment(by: contact) }
    }
}
