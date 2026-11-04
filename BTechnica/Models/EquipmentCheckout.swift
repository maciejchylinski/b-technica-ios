import Foundation

/// Who receives an item when it is issued.
enum EquipmentRecipient: Hashable {
    /// A person from the project contact list.
    case person(UUID)
    /// A company from the project contact list.
    case company(UUID)
    /// Someone not in contacts (visitor, agency worker…).
    case freeText

    var kind: String {
        switch self {
        case .person: return "person"
        case .company: return "company"
        case .freeText: return "text"
        }
    }
}

/// How a checkout ended.
enum EquipmentCheckoutOutcome: String, CaseIterable {
    case returned
    case damaged
    case lost
    /// Closed because the item went straight to another holder / project.
    case handedOver

    var label: String {
        switch self {
        case .returned: return "Returned"
        case .damaged: return "Returned damaged"
        case .lost: return "Lost"
        case .handedOver: return "Handed over"
        }
    }
}

/// One issue → return cycle of an equipment item. Open while `returnedDate == nil`;
/// at most one open checkout exists per item (enforced by a unique partial index).
struct EquipmentCheckout: Identifiable, Equatable, Hashable {
    var id: UUID
    var equipmentId: UUID
    var projectId: UUID?
    var recipient: EquipmentRecipient
    /// Name snapshot at issue time; shown when the contact is later edited or deleted.
    var recipientName: String
    var location: String?
    var notes: String?
    var issuedDate: Date
    var returnedDate: Date?
    var outcome: EquipmentCheckoutOutcome?
    var returnNotes: String?

    var isActive: Bool { returnedDate == nil }

    var personId: UUID? {
        if case .person(let id) = recipient { return id }
        return nil
    }

    var companyId: UUID? {
        if case .company(let id) = recipient { return id }
        return nil
    }
}

/// Condition reported when an item comes back.
enum EquipmentReturnCondition: String, CaseIterable, Identifiable {
    case good
    case damaged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .good: return "Good"
        case .damaged: return "Damaged"
        }
    }
}
