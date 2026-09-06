import Foundation

/// Supported real-world length units for scale calibration input.
enum LengthUnit: String, Codable, CaseIterable, Identifiable {
    case mm
    case cm
    case m

    var id: String { rawValue }

    /// Human readable label shown in the UI.
    var label: String {
        switch self {
        case .mm: return "mm"
        case .cm: return "cm"
        case .m: return "m"
        }
    }

    /// Convert a value expressed in this unit into millimetres.
    /// Millimetres are the canonical storage unit for all calibration data.
    func toMillimeters(_ value: Double) -> Double {
        switch self {
        case .mm: return value
        case .cm: return value * 10.0
        case .m: return value * 1000.0
        }
    }
}
