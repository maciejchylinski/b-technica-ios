import Foundation

/// Current on-disk document schema. Bump when making breaking `AppData` / model changes.
enum AppDataSchema {
    static let current = 1
}

/// Root persisted document for the whole app. Everything is stored in a single
/// JSON file for this first slice — simple, offline-first, and easy to reason
/// about. If/when the data grows this can be swapped for SwiftData without
/// changing the feature code that talks to `AppStore`.
struct AppData: Codable {
    /// Document format version. Missing in older files is treated as `0`.
    var schemaVersion: Int
    var project: Project
    var drawings: [Drawing]
    var issues: [Issue]
    var equipment: [EquipmentItem]
    /// Local contractor dictionary (picker options).
    var contractors: [Contractor]
    /// Local discipline / category dictionary (picker options).
    var disciplines: [Discipline]

    init(project: Project,
         drawings: [Drawing] = [],
         issues: [Issue] = [],
         equipment: [EquipmentItem] = [],
         contractors: [Contractor] = [],
         disciplines: [Discipline] = [],
         schemaVersion: Int = AppDataSchema.current) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.drawings = drawings
        self.issues = issues
        self.equipment = equipment
        self.contractors = contractors
        self.disciplines = disciplines
    }

    // MARK: - Codable (backward compatible with older appdata.json)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, drawings, issues, equipment, contractors, disciplines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older files omit the key → version 0; migrate upward in AppStore.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        project = try c.decode(Project.self, forKey: .project)
        drawings = try c.decodeIfPresent([Drawing].self, forKey: .drawings) ?? []
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        equipment = try c.decodeIfPresent([EquipmentItem].self, forKey: .equipment) ?? []
        contractors = try c.decodeIfPresent([Contractor].self, forKey: .contractors) ?? []
        disciplines = try c.decodeIfPresent([Discipline].self, forKey: .disciplines) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(project, forKey: .project)
        try c.encode(drawings, forKey: .drawings)
        try c.encode(issues, forKey: .issues)
        try c.encode(equipment, forKey: .equipment)
        try c.encode(contractors, forKey: .contractors)
        try c.encode(disciplines, forKey: .disciplines)
    }
}
