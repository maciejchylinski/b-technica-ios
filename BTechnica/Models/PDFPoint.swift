import Foundation
import CoreGraphics

/// A point expressed in **PDF page coordinates** (origin bottom-left, PDF units).
///
/// We deliberately store plain `Double`s instead of `CGPoint` so it is always
/// unambiguous that these values live in the PDF page coordinate space and are
/// persisted independently of any screen / view geometry. This is the
/// foundation for future measurements and issue pins, which must all be
/// anchored to the drawing itself rather than to the device screen.
struct PDFPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
