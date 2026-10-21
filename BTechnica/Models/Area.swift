import Foundation
import UIKit

/// A named polygon region on a PDF drawing page.
///
/// Vertices are always stored in **PDF page coordinates** (origin bottom-left),
/// never screen/view coordinates, so overlays stay glued through zoom and pan.
/// Field layout mirrors Supabase `areas` (local `pageIndex` ↔ remote `page_id` on sync).
struct Area: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var projectId: UUID
    var drawingId: UUID
    /// Zero-based PDF page index (resolved to `drawing_pages.id` on future sync).
    var pageIndex: Int
    var name: String
    /// Polygon vertices in PDF page coordinates. At least three when saved.
    var vertices: [PDFPoint]
    /// Hex color string, e.g. `#007AFF` (matches Supabase `areas.color`).
    var color: String
    /// Fill opacity in 0…1 (matches Supabase `areas.opacity`).
    var opacity: Double
    /// Per-area visibility flag (matches Supabase `areas.is_visible`).
    var isVisible: Bool
    var createdDate: Date
    var updatedDate: Date

    static let defaultColor = "#007AFF"
    static let defaultOpacity = 0.35

    /// Preset swatches offered when creating or renaming an area.
    static let colorPresets: [(name: String, hex: String)] = [
        ("Blue", "#007AFF"),
        ("Red", "#FF3B30"),
        ("Green", "#34C759"),
        ("Orange", "#FF9500"),
        ("Purple", "#AF52DE"),
        ("Teal", "#5AC8FA")
    ]

    init(
        id: UUID = UUID(),
        projectId: UUID,
        drawingId: UUID,
        pageIndex: Int,
        name: String,
        vertices: [PDFPoint],
        color: String = Area.defaultColor,
        opacity: Double = Area.defaultOpacity,
        isVisible: Bool = true,
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.drawingId = drawingId
        self.pageIndex = pageIndex
        self.name = name
        self.vertices = vertices
        self.color = color
        self.opacity = opacity
        self.isVisible = isVisible
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    /// UIKit color for fill/stroke rendering.
    var uiColor: UIColor {
        UIColor(hex: color) ?? UIColor.systemBlue
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, projectId, drawingId, pageIndex, name, vertices, color, opacity, isVisible
        case createdDate, updatedDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        drawingId = try c.decode(UUID.self, forKey: .drawingId)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        name = try c.decode(String.self, forKey: .name)
        vertices = try c.decode([PDFPoint].self, forKey: .vertices)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? Area.defaultColor
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Area.defaultOpacity
        opacity = min(1, max(0, rawOpacity))
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
        updatedDate = try c.decodeIfPresent(Date.self, forKey: .updatedDate) ?? createdDate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(drawingId, forKey: .drawingId)
        try c.encode(pageIndex, forKey: .pageIndex)
        try c.encode(name, forKey: .name)
        try c.encode(vertices, forKey: .vertices)
        try c.encode(color, forKey: .color)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(createdDate, forKey: .createdDate)
        try c.encode(updatedDate, forKey: .updatedDate)
    }
}

extension UIColor {
    /// Parses `#RRGGBB` or `RRGGBB` hex strings. Returns nil when invalid.
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
