import Foundation

/// Status of a field issue. Kept intentionally small for the MVP.
enum IssueStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case open
    case inProgress
    case resolved
    case closed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .resolved: return "Resolved"
        case .closed: return "Closed"
        }
    }
}

/// A field issue pinned to a specific location on a drawing.
///
/// Location is always stored in **PDF page coordinates** (`pdfX` / `pdfY`),
/// never screen coordinates or percentages. Pins stay attached to the drawing
/// through zoom and pan because PDFKit converts these values at draw time.
///
/// Photos are stored as metadata here; image bytes live as files under
/// Documents/IssuePhotos/. Future additions (not in this slice):
///  - assignee, due date, comments / activity log,
///  - sync / reports.
struct Issue: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var drawingId: UUID
    /// Zero-based PDF page index.
    var pageIndex: Int
    /// Pin X in PDF page coordinates (origin bottom-left).
    var pdfX: Double
    /// Pin Y in PDF page coordinates (origin bottom-left).
    var pdfY: Double
    /// Stable project-wide display number (e.g. pin label `#3`).
    var number: Int
    var title: String
    /// Longer description shown in the form / detail screen.
    var details: String
    var status: IssueStatus
    /// Optional discipline / category (e.g. Electrical, HVAC).
    var discipline: String?
    /// Optional contractor name.
    var contractor: String?
    var createdDate: Date
    /// Local photo attachments (file references, not image blobs).
    var photos: [IssuePhoto]

    init(id: UUID = UUID(),
         drawingId: UUID,
         pageIndex: Int,
         pdfX: Double,
         pdfY: Double,
         number: Int,
         title: String,
         details: String = "",
         status: IssueStatus = .open,
         discipline: String? = nil,
         contractor: String? = nil,
         createdDate: Date = Date(),
         photos: [IssuePhoto] = []) {
        self.id = id
        self.drawingId = drawingId
        self.pageIndex = pageIndex
        self.pdfX = pdfX
        self.pdfY = pdfY
        self.number = number
        self.title = title
        self.details = details
        self.status = status
        self.discipline = discipline
        self.contractor = contractor
        self.createdDate = createdDate
        self.photos = photos
    }

    var pdfPoint: PDFPoint { PDFPoint(x: pdfX, y: pdfY) }

    /// Convenience for creating from a `PDFPoint`.
    init(id: UUID = UUID(),
         drawingId: UUID,
         pageIndex: Int,
         point: PDFPoint,
         number: Int,
         title: String,
         details: String = "",
         status: IssueStatus = .open,
         discipline: String? = nil,
         contractor: String? = nil,
         createdDate: Date = Date(),
         photos: [IssuePhoto] = []) {
        self.init(id: id,
                  drawingId: drawingId,
                  pageIndex: pageIndex,
                  pdfX: point.x,
                  pdfY: point.y,
                  number: number,
                  title: title,
                  details: details,
                  status: status,
                  discipline: discipline,
                  contractor: contractor,
                  createdDate: createdDate,
                  photos: photos)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, drawingId, pageIndex, pdfX, pdfY, number, title, details, status
        case discipline, contractor, createdDate, photos
        /// Legacy keys from the foundation-only Issue model.
        case x, y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        drawingId = try c.decode(UUID.self, forKey: .drawingId)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        if let x = try c.decodeIfPresent(Double.self, forKey: .pdfX) {
            pdfX = x
        } else {
            pdfX = try c.decode(Double.self, forKey: .x)
        }
        if let y = try c.decodeIfPresent(Double.self, forKey: .pdfY) {
            pdfY = y
        } else {
            pdfY = try c.decode(Double.self, forKey: .y)
        }
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        status = try c.decodeIfPresent(IssueStatus.self, forKey: .status) ?? .open
        discipline = try c.decodeIfPresent(String.self, forKey: .discipline)
        contractor = try c.decodeIfPresent(String.self, forKey: .contractor)
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
        photos = try c.decodeIfPresent([IssuePhoto].self, forKey: .photos) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(drawingId, forKey: .drawingId)
        try c.encode(pageIndex, forKey: .pageIndex)
        try c.encode(pdfX, forKey: .pdfX)
        try c.encode(pdfY, forKey: .pdfY)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(discipline, forKey: .discipline)
        try c.encodeIfPresent(contractor, forKey: .contractor)
        try c.encode(createdDate, forKey: .createdDate)
        try c.encode(photos, forKey: .photos)
    }
}
