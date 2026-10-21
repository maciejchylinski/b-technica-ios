import Foundation

/// A single drawing / PDF document that lives inside a project.
///
/// The PDF file itself is copied into the app's local Documents directory on
/// import; `fileName` is the path **relative** to that directory so the record
/// stays valid even if the app container's absolute path changes between
/// launches (which it does on iOS).
struct Drawing: Codable, Identifiable, Equatable {
    var id: UUID
    var projectId: UUID
    /// Parent folder; `nil` means the drawing sits at the project root.
    /// Matches Supabase `drawings.folder_id`.
    var folderId: UUID?
    var name: String
    /// File name relative to Documents/Drawings, e.g. "<uuid>.pdf".
    var fileName: String
    var pageCount: Int
    var createdDate: Date
    /// Optional revision label as printed on the sheet (e.g. "C", "0").
    var revision: String?
    /// Optional discipline or drawing type (e.g. Architectural, Electrical).
    var discipline: String?
    /// Optional level / location (e.g. "Level 2", "Grid A-B").
    var location: String?
    /// Optional date printed on the drawing, if the user recorded one.
    var drawingDate: Date?
    /// One calibration entry per calibrated page. A drawing counts as
    /// "Calibrated" as soon as at least one page has a calibration.
    var calibrations: [PageCalibration]

    init(id: UUID = UUID(),
         projectId: UUID,
         folderId: UUID? = nil,
         name: String,
         fileName: String,
         pageCount: Int,
         createdDate: Date = Date(),
         revision: String? = nil,
         discipline: String? = nil,
         location: String? = nil,
         drawingDate: Date? = nil,
         calibrations: [PageCalibration] = []) {
        self.id = id
        self.projectId = projectId
        self.folderId = folderId
        self.name = name
        self.fileName = fileName
        self.pageCount = pageCount
        self.createdDate = createdDate
        self.revision = revision
        self.discipline = discipline
        self.location = location
        self.drawingDate = drawingDate
        self.calibrations = calibrations
    }

    var isCalibrated: Bool { !calibrations.isEmpty }

    var isMultiPage: Bool { pageCount > 1 }

    /// User-facing page label; nil for single-page drawings (Page 1 is implied).
    func pageLabel(for pageIndex: Int) -> String? {
        guard isMultiPage else { return nil }
        return "Page \(pageIndex + 1)"
    }

    var calibrationStatusText: String { isCalibrated ? "Scale set" : "No scale" }

    var displayRevision: String? { Self.nonEmpty(revision) }
    var displayDiscipline: String? { Self.nonEmpty(discipline) }
    var displayLocation: String? { Self.nonEmpty(location) }

    /// Name plus revision and location when set — used on issues and reports.
    var issueReferenceLabel: String {
        var parts = [name]
        if let revision = displayRevision {
            parts.append("Rev \(revision)")
        }
        if let location = displayLocation {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    func calibration(forPage pageIndex: Int) -> PageCalibration? {
        calibrations.first { $0.pageIndex == pageIndex }
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Codable (new metadata keys are optional for older appdata.json)

    private enum CodingKeys: String, CodingKey {
        case id, projectId, folderId, name, fileName, pageCount, createdDate
        case revision, discipline, location, drawingDate, calibrations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        folderId = try c.decodeIfPresent(UUID.self, forKey: .folderId)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        discipline = try c.decodeIfPresent(String.self, forKey: .discipline)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        drawingDate = try c.decodeIfPresent(Date.self, forKey: .drawingDate)
        calibrations = try c.decodeIfPresent([PageCalibration].self, forKey: .calibrations) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(folderId, forKey: .folderId)
        try c.encode(name, forKey: .name)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(createdDate, forKey: .createdDate)
        try c.encodeIfPresent(Drawing.nonEmpty(revision), forKey: .revision)
        try c.encodeIfPresent(Drawing.nonEmpty(discipline), forKey: .discipline)
        try c.encodeIfPresent(Drawing.nonEmpty(location), forKey: .location)
        try c.encodeIfPresent(drawingDate, forKey: .drawingDate)
        try c.encode(calibrations, forKey: .calibrations)
    }
}
