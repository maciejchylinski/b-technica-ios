import Foundation

/// Bundled sample floor-plan PDFs for testing and demos.
enum SampleDrawing: String, CaseIterable, Identifiable {
    case apartment
    case office
    case staircase

    var id: String { rawValue }

    var bundleResourceName: String { "sample-\(rawValue)" }

    var defaultName: String {
        switch self {
        case .apartment: return "Apartment floor plan"
        case .office: return "Office floor plan"
        case .staircase: return "Common area / staircase"
        }
    }

    var subtitle: String {
        switch self {
        case .apartment: return "Minimal residential layout"
        case .office: return "Open-plan workspace"
        case .staircase: return "Landing and stair core"
        }
    }
}
