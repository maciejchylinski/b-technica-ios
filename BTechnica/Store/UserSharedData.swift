import Foundation

/// User-scoped local dictionaries shared across all cloud projects on this device.
/// Stored separately from per-project drawings/issues. Not synced to Supabase yet.
struct UserSharedData: Codable, Equatable {
    var schemaVersion: Int
    var contractors: [Contractor]
    var equipment: [EquipmentItem]
    var disciplines: [Discipline]

    init(
        contractors: [Contractor] = [],
        equipment: [EquipmentItem] = [],
        disciplines: [Discipline] = [],
        schemaVersion: Int = AppDataSchema.current
    ) {
        self.schemaVersion = schemaVersion
        self.contractors = contractors
        self.equipment = equipment
        self.disciplines = disciplines
    }
}
