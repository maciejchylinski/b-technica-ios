import Foundation

/// Status of a tracked equipment / inventory item.
enum EquipmentStatus: String, Codable, CaseIterable, Identifiable {
    case available
    case issued
    case returned
    case lost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: return "Available"
        case .issued: return "Issued"
        case .returned: return "Returned"
        case .lost: return "Lost"
        }
    }
}

/// A piece of site equipment / inventory.
///
/// PRODUCT NOTE: The Equipment module is a placeholder in this first slice.
/// When implemented it will let site teams track tools and materials with:
///   - `item`        — what the thing is,
///   - `issuedTo`    — the person / crew currently holding it,
///   - `location`    — where it lives on site,
///   - `issuedDate`  — when it was handed out,
///   - `returnedDate`— when it came back (nil while still out),
///   - `status`      — available / issued / returned / lost.
/// This struct captures that shape now so the storage layer is ready; no
/// Equipment UI beyond the placeholder tab is built yet.
struct EquipmentItem: Codable, Identifiable, Equatable {
    var id: UUID
    var item: String
    var issuedTo: String?
    var location: String?
    var issuedDate: Date?
    var returnedDate: Date?
    var status: EquipmentStatus

    init(id: UUID = UUID(),
         item: String,
         issuedTo: String? = nil,
         location: String? = nil,
         issuedDate: Date? = nil,
         returnedDate: Date? = nil,
         status: EquipmentStatus = .available) {
        self.id = id
        self.item = item
        self.issuedTo = issuedTo
        self.location = location
        self.issuedDate = issuedDate
        self.returnedDate = returnedDate
        self.status = status
    }
}
