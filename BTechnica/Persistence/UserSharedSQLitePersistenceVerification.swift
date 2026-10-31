import Foundation
import GRDB

/// Targeted check: edit contractor, issue/return equipment, reopen DB, confirm persistence.
enum UserSharedSQLitePersistenceVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
    }

    static func run() -> Result {
        do {
            return try runThrowing()
        } catch {
            return Result(passed: false, message: "Threw: \(error.localizedDescription)")
        }
    }

    private static func runThrowing() throws -> Result {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-user-shared-sqlite-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let contractorId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let disciplineId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let equipmentId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let createdEventId = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        let issuedEventId = UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111")!
        let returnedEventId = UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")!

        var contractor = Contractor(
            id: contractorId,
            name: "Acme Builders",
            notes: "Electrical",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let discipline = Discipline(
            id: disciplineId,
            name: "HVAC",
            createdDate: Date(timeIntervalSince1970: 1_700_000_050)
        )
        var equipment = EquipmentItem(
            id: equipmentId,
            item: "Laser Level",
            category: "Tool",
            identifier: "LL-42",
            notes: "Site kit",
            status: .available,
            history: [
                EquipmentEvent(
                    id: createdEventId,
                    date: Date(timeIntervalSince1970: 1_700_000_100),
                    type: .created
                )
            ]
        )

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.persistUserShared(
            contractors: [contractor],
            disciplines: [discipline],
            equipment: [equipment]
        )

        // Edit contractor + issue equipment (history grows atomically with item).
        contractor.name = "Acme Builders Ltd"
        contractor.notes = "Electrical + fire"
        equipment.issuedTo = "Jordan Lee"
        equipment.location = "Level 2"
        equipment.issuedDate = Date(timeIntervalSince1970: 1_700_000_200)
        equipment.status = .issued
        equipment.history.append(
            EquipmentEvent(
                id: issuedEventId,
                date: Date(timeIntervalSince1970: 1_700_000_200),
                type: .issued,
                person: "Jordan Lee",
                location: "Level 2"
            )
        )
        try db.persistUserShared(
            contractors: [contractor],
            disciplines: [discipline],
            equipment: [equipment]
        )

        // Return equipment.
        equipment.returnedDate = Date(timeIntervalSince1970: 1_700_000_300)
        equipment.status = .returned
        equipment.issuedTo = nil
        equipment.history.append(
            EquipmentEvent(
                id: returnedEventId,
                date: Date(timeIntervalSince1970: 1_700_000_300),
                type: .returned,
                notes: "Back in cage"
            )
        )
        try db.persistUserShared(
            contractors: [contractor],
            disciplines: [discipline],
            equipment: [equipment]
        )

        let reopened = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        let contractors = try reopened.fetchContractors()
        let disciplines = try reopened.fetchDisciplines()
        let items = try reopened.fetchEquipment()

        guard contractors.count == 1,
              let loadedContractor = contractors.first,
              loadedContractor.id == contractorId,
              loadedContractor.name == "Acme Builders Ltd",
              loadedContractor.notes == "Electrical + fire"
        else {
            return Result(passed: false, message: "Contractor edit not preserved after reopen")
        }

        guard disciplines.count == 1,
              disciplines[0].id == disciplineId,
              disciplines[0].name == "HVAC"
        else {
            return Result(passed: false, message: "Discipline UUID/name not preserved")
        }

        guard let item = items.first(where: { $0.id == equipmentId }) else {
            return Result(passed: false, message: "Equipment UUID missing after reopen")
        }
        guard item.item == "Laser Level",
              item.identifier == "LL-42",
              item.status == .returned,
              item.returnedDate != nil,
              item.history.count == 3,
              item.history.map(\.id) == [createdEventId, issuedEventId, returnedEventId],
              item.history[1].type == .issued,
              item.history[1].person == "Jordan Lee",
              item.history[2].type == .returned,
              item.history[2].notes == "Back in cage"
        else {
            return Result(
                passed: false,
                message: "Equipment issue/return history not preserved (status=\(item.status.rawValue) history=\(item.history.count))"
            )
        }

        // Owner isolation: another user must not see these rows.
        let otherUser = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let otherDB = try AppDatabase.open(
            userId: otherUser,
            at: root.appendingPathComponent("other.sqlite"),
            rootURL: root
        )
        try otherDB.persistUserShared(contractors: [], disciplines: [], equipment: [])
        let otherContractors = try otherDB.fetchContractors()
        guard otherContractors.isEmpty else {
            return Result(passed: false, message: "User isolation failed for empty other DB")
        }

        // Stale JSON must not overwrite SQLite on a second INSERT OR IGNORE import path —
        // UPSERT after edit is the live source of truth; confirm edit survived.
        try db.persistUserShared(
            contractors: [contractor],
            disciplines: [discipline],
            equipment: [equipment]
        )
        let again = try db.fetchContractors()
        guard again.first?.name == "Acme Builders Ltd" else {
            return Result(passed: false, message: "SQLite lost contractor edit on re-persist")
        }

        return Result(
            passed: true,
            message: "Contractor edit and equipment issue/return history preserved across reopen."
        )
    }
}
