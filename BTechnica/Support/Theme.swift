import SwiftUI

/// Lightweight design tokens for a clean white/blue field-app look.
/// Kept small on purpose — no heavy design system for this slice.
enum Theme {
    /// Primary brand blue used for actions and highlights.
    static let blue = Color(red: 0.11, green: 0.48, blue: 0.90)
    /// Neutral page background.
    static let background = Color(.systemGroupedBackground)
    /// Card / surface background.
    static let surface = Color(.secondarySystemGroupedBackground)

    /// Minimum comfortable touch target for on-site use with gloves.
    static let touchTarget: CGFloat = 48
}
