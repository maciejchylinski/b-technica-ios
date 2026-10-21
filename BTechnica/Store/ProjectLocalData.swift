import Foundation

/// Per-project local workspace document (folders, drawings, issues, project metadata).
/// Keyed on disk by `Users/<userId>/Projects/<projectId>/`. Not synced to Supabase yet.
struct ProjectLocalData: Codable, Equatable {
    var schemaVersion: Int
    var project: Project
    var drawingFolders: [DrawingFolder]
    var drawings: [Drawing]
    var issues: [Issue]

    init(
        project: Project,
        drawingFolders: [DrawingFolder] = [],
        drawings: [Drawing] = [],
        issues: [Issue] = [],
        schemaVersion: Int = AppDataSchema.current
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.drawingFolders = drawingFolders
        self.drawings = drawings
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, drawingFolders, drawings, issues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        project = try c.decode(Project.self, forKey: .project)
        drawingFolders = try c.decodeIfPresent([DrawingFolder].self, forKey: .drawingFolders) ?? []
        drawings = try c.decodeIfPresent([Drawing].self, forKey: .drawings) ?? []
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(project, forKey: .project)
        try c.encode(drawingFolders, forKey: .drawingFolders)
        try c.encode(drawings, forKey: .drawings)
        try c.encode(issues, forKey: .issues)
    }
}
