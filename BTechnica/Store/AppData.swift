import Foundation

/// Current on-disk document schema. Bump when making breaking `AppData` / model changes.
enum AppDataSchema {
    /// v2: nested `drawingFolders` + optional `Drawing.folderId`.
    static let current = 2
}

/// In-memory root document for one local project workspace plus user-global
/// dictionaries. On disk these are split:
/// - `ProjectLocalData` → `Users/<userId>/Projects/<projectId>/appdata.json`
/// - `UserSharedData` → `Users/<userId>/userdata.json`
/// Cloud project membership/names live in Supabase; this file is local-only (not synced yet).
struct AppData: Codable {
    /// Document format version. Missing in older files is treated as `0`.
    var schemaVersion: Int
    var project: Project
    /// Nested drawing folders for this project (local; IDs match Supabase shape).
    var drawingFolders: [DrawingFolder]
    var drawings: [Drawing]
    var issues: [Issue]
    var equipment: [EquipmentItem]
    /// Local contractor dictionary (picker options).
    var contractors: [Contractor]
    /// Local discipline / category dictionary (picker options).
    var disciplines: [Discipline]

    init(project: Project,
         drawingFolders: [DrawingFolder] = [],
         drawings: [Drawing] = [],
         issues: [Issue] = [],
         equipment: [EquipmentItem] = [],
         contractors: [Contractor] = [],
         disciplines: [Discipline] = [],
         schemaVersion: Int = AppDataSchema.current) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.drawingFolders = drawingFolders
        self.drawings = drawings
        self.issues = issues
        self.equipment = equipment
        self.contractors = contractors
        self.disciplines = disciplines
    }

    // MARK: - Codable (backward compatible with older appdata.json)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, drawingFolders, drawings, issues, equipment, contractors, disciplines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older files omit the key → version 0; migrate upward in AppStore.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        project = try c.decode(Project.self, forKey: .project)
        drawingFolders = try c.decodeIfPresent([DrawingFolder].self, forKey: .drawingFolders) ?? []
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
        try c.encode(drawingFolders, forKey: .drawingFolders)
        try c.encode(drawings, forKey: .drawings)
        try c.encode(issues, forKey: .issues)
        try c.encode(equipment, forKey: .equipment)
        try c.encode(contractors, forKey: .contractors)
        try c.encode(disciplines, forKey: .disciplines)
    }
}
