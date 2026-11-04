import Foundation

/// User-wide equipment register with checkout state, backed by the per-user SQLite database.
/// `projectId` is the active project: new checkouts are recorded against it and recipients
/// come from its contact list. Local only; not synced to Supabase yet.
@MainActor
final class EquipmentStore: ObservableObject {
    @Published private(set) var items: [EquipmentItem] = []
    @Published private(set) var checkouts: [EquipmentCheckout] = []
    @Published private(set) var projectNames: [UUID: String] = [:]
    @Published var errorMessage: String?

    let userId: UUID
    let projectId: UUID
    private let database: AppDatabase?

    init(userId: UUID, projectId: UUID) {
        self.userId = userId
        self.projectId = projectId
        do {
            let database = try AppDatabase.shared(for: userId)
            try database.normalizeEquipment()
            self.database = database
        } catch {
            database = nil
            errorMessage = "Equipment could not be opened: \(error.localizedDescription)"
        }
        reload()
    }

    func reload() {
        guard let database else { return }
        do {
            items = try database.fetchEquipment()
            checkouts = try database.fetchEquipmentCheckouts()
            projectNames = try database.fetchLocalProjectNames()
        } catch {
            errorMessage = "Equipment could not be loaded: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup

    func item(id: UUID) -> EquipmentItem? {
        items.first { $0.id == id }
    }

    func activeCheckout(for itemId: UUID) -> EquipmentCheckout? {
        checkouts.first { $0.equipmentId == itemId && $0.isActive }
    }

    func checkouts(for itemId: UUID) -> [EquipmentCheckout] {
        checkouts.filter { $0.equipmentId == itemId }
    }

    func projectName(_ id: UUID?) -> String? {
        id.flatMap { projectNames[$0] }
    }

    /// Distinct holders of currently issued items, for the holder filter.
    var activeHolders: [EquipmentHolder] {
        var seen = Set<EquipmentHolder>()
        var result: [EquipmentHolder] = []
        for checkout in checkouts where checkout.isActive {
            let holder = EquipmentHolder(checkout)
            if seen.insert(holder).inserted { result.append(holder) }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var categories: [String] {
        Array(Set(items.compactMap(\.displayCategory))).sorted()
    }

    // MARK: - Mutations (nil on success, user-facing message on failure)

    @discardableResult
    func create(name: String, category: String?, identifier: String?, serialNumber: String?, notes: String?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name." }
        let item = EquipmentItem(item: name, category: category, identifier: identifier,
                                 serialNumber: serialNumber, notes: notes)
        return perform { try $0.createEquipment(item) }
    }

    @discardableResult
    func update(id: UUID, name: String, category: String?, identifier: String?, serialNumber: String?, notes: String?) -> String? {
        guard var item = item(id: id) else { return EquipmentActionError.notFound.errorDescription }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name." }
        let updated = EquipmentItem(item: name, category: category, identifier: identifier,
                                    serialNumber: serialNumber, notes: notes)
        guard updated.item != item.item || updated.category != item.category
                || updated.identifier != item.identifier || updated.serialNumber != item.serialNumber
                || updated.notes != item.notes else { return nil }
        item.item = updated.item
        item.category = updated.category
        item.identifier = updated.identifier
        item.serialNumber = updated.serialNumber
        item.notes = updated.notes
        return perform { try $0.updateEquipmentDetails(item) }
    }

    @discardableResult
    func issue(id: UUID, recipient: EquipmentRecipient, recipientName: String?, location: String?,
               date: Date, notes: String?, handOver: Bool) -> String? {
        let request = AppDatabase.EquipmentIssueRequest(
            equipmentId: id, projectId: projectId, recipient: recipient, recipientName: recipientName,
            location: location, date: date, notes: notes, handOver: handOver
        )
        return perform { try $0.issueEquipment(request) }
    }

    @discardableResult
    func returnItem(id: UUID, date: Date, condition: EquipmentReturnCondition, notes: String?) -> String? {
        perform { try $0.returnEquipment(id: id, date: date, condition: condition, notes: notes) }
    }

    @discardableResult
    func mark(id: UUID, status: EquipmentStatus, notes: String?) -> String? {
        perform { try $0.markEquipment(id: id, status: status, notes: notes) }
    }

    @discardableResult
    func restore(id: UUID, notes: String?) -> String? {
        perform { try $0.restoreEquipment(id: id, notes: notes) }
    }

    @discardableResult
    func delete(id: UUID) -> String? {
        perform { try $0.deleteEquipment(id: id) }
    }

    private func perform(_ write: (AppDatabase) throws -> Void) -> String? {
        guard let database else { return "Equipment storage is not available." }
        defer { reload() }
        do {
            try write(database)
            return nil
        } catch let error as EquipmentActionError {
            return error.errorDescription
        } catch {
            return "Equipment could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Holder identity for filtering: a contact, or a free-text name.
struct EquipmentHolder: Hashable, Identifiable {
    var recipient: EquipmentRecipient
    var name: String

    init(_ checkout: EquipmentCheckout) {
        recipient = checkout.recipient
        name = checkout.recipientName
    }

    var id: String {
        switch recipient {
        case .person(let id): return "person-\(id.uuidString)"
        case .company(let id): return "company-\(id.uuidString)"
        case .freeText: return "text-\(name.lowercased())"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func matches(_ checkout: EquipmentCheckout) -> Bool {
        EquipmentHolder(checkout) == self
    }

    var systemImage: String {
        switch recipient {
        case .person: return "person.crop.circle"
        case .company: return "building.2"
        case .freeText: return "person.fill.questionmark"
        }
    }
}
