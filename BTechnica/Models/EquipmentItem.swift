import Foundation

/// Status of a tracked equipment / inventory item.
enum EquipmentStatus: String, Codable, CaseIterable, Identifiable {
    case available
    case issued
    case returned
    case damaged
    case lost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: return "Available"
        case .issued: return "Issued"
        case .returned: return "Returned"
        case .damaged: return "Damaged"
        case .lost: return "Lost"
        }
    }
}

/// A single history entry for an equipment item.
enum EquipmentEventType: String, Codable, CaseIterable, Identifiable {
    case created
    case issued
    case returned
    case markedDamaged
    case markedLost
    case edited

    var id: String { rawValue }

    var label: String {
        switch self {
        case .created: return "Created"
        case .issued: return "Issued"
        case .returned: return "Returned"
        case .markedDamaged: return "Marked damaged"
        case .markedLost: return "Marked lost"
        case .edited: return "Edited"
        }
    }
}

struct EquipmentEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var type: EquipmentEventType
    /// Person / company when relevant (e.g. issued to).
    var person: String?
    var location: String?
    var notes: String?

    init(id: UUID = UUID(),
         date: Date = Date(),
         type: EquipmentEventType,
         person: String? = nil,
         location: String? = nil,
         notes: String? = nil) {
        self.id = id
        self.date = date
        self.type = type
        self.person = Self.nonEmpty(person)
        self.location = Self.nonEmpty(location)
        self.notes = Self.nonEmpty(notes)
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A piece of site equipment / inventory tracked locally on device.
struct EquipmentItem: Codable, Identifiable, Equatable {
    var id: UUID
    /// Display name (stored as `item` for backward compatibility with early appdata.json).
    var item: String
    /// Optional type / category (e.g. Tool, Meter, PPE).
    var category: String?
    /// Optional identifier / serial number.
    var identifier: String?
    var notes: String?
    var issuedTo: String?
    var location: String?
    var issuedDate: Date?
    var returnedDate: Date?
    var status: EquipmentStatus
    var history: [EquipmentEvent]

    init(id: UUID = UUID(),
         item: String,
         category: String? = nil,
         identifier: String? = nil,
         notes: String? = nil,
         issuedTo: String? = nil,
         location: String? = nil,
         issuedDate: Date? = nil,
         returnedDate: Date? = nil,
         status: EquipmentStatus = .available,
         history: [EquipmentEvent] = []) {
        self.id = id
        self.item = item
        self.category = Self.nonEmpty(category)
        self.identifier = Self.nonEmpty(identifier)
        self.notes = Self.nonEmpty(notes)
        self.issuedTo = Self.nonEmpty(issuedTo)
        self.location = Self.nonEmpty(location)
        self.issuedDate = issuedDate
        self.returnedDate = returnedDate
        self.status = status
        self.history = history
    }

    var displayName: String { item }

    var displayCategory: String? { Self.nonEmpty(category) }
    var displayIdentifier: String? { Self.nonEmpty(identifier) }
    var displayNotes: String? { Self.nonEmpty(notes) }
    var displayIssuedTo: String? { Self.nonEmpty(issuedTo) }
    var displayLocation: String? { Self.nonEmpty(location) }

    /// Whether the item can be handed out (available or back from a prior return).
    var canIssue: Bool {
        status == .available || status == .returned
    }

    var canReturn: Bool {
        status == .issued
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Codable (new keys optional for older appdata.json)

    private enum CodingKeys: String, CodingKey {
        case id, item, category, identifier, notes
        case issuedTo, location, issuedDate, returnedDate, status, history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        item = try c.decode(String.self, forKey: .item)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        issuedTo = try c.decodeIfPresent(String.self, forKey: .issuedTo)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        issuedDate = try c.decodeIfPresent(Date.self, forKey: .issuedDate)
        returnedDate = try c.decodeIfPresent(Date.self, forKey: .returnedDate)
        status = try c.decodeIfPresent(EquipmentStatus.self, forKey: .status) ?? .available
        history = try c.decodeIfPresent([EquipmentEvent].self, forKey: .history) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(item, forKey: .item)
        try c.encodeIfPresent(Self.nonEmpty(category), forKey: .category)
        try c.encodeIfPresent(Self.nonEmpty(identifier), forKey: .identifier)
        try c.encodeIfPresent(Self.nonEmpty(notes), forKey: .notes)
        try c.encodeIfPresent(Self.nonEmpty(issuedTo), forKey: .issuedTo)
        try c.encodeIfPresent(Self.nonEmpty(location), forKey: .location)
        try c.encodeIfPresent(issuedDate, forKey: .issuedDate)
        try c.encodeIfPresent(returnedDate, forKey: .returnedDate)
        try c.encode(status, forKey: .status)
        try c.encode(history, forKey: .history)
    }
}
