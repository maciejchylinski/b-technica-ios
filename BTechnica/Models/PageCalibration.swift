import Foundation

/// Scale calibration for a single page of a drawing.
///
/// Calibration is captured by having the user tap two points on the PDF and
/// entering the real-world distance between them. Everything is stored in PDF
/// page coordinates so the scale stays valid regardless of zoom / device.
struct PageCalibration: Codable, Equatable, Identifiable {
    var id: UUID
    /// Zero-based index of the calibrated page.
    var pageIndex: Int
    /// First tapped reference point, in PDF page coordinates.
    var pointA: PDFPoint
    /// Second tapped reference point, in PDF page coordinates.
    var pointB: PDFPoint
    /// The real-world distance between A and B, normalised to millimetres.
    var realDistanceMM: Double
    /// The unit the user originally entered (kept for display).
    var enteredUnit: LengthUnit
    /// The raw value the user originally entered (kept for display).
    var enteredValue: Double
    /// Millimetres represented by one PDF unit at this scale.
    var mmPerPDFUnit: Double
    var calibratedDate: Date

    init(pageIndex: Int,
         pointA: PDFPoint,
         pointB: PDFPoint,
         enteredValue: Double,
         enteredUnit: LengthUnit,
         calibratedDate: Date = Date()) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.pointA = pointA
        self.pointB = pointB
        self.enteredValue = enteredValue
        self.enteredUnit = enteredUnit
        self.realDistanceMM = enteredUnit.toMillimeters(enteredValue)
        self.calibratedDate = calibratedDate

        let dx = pointB.x - pointA.x
        let dy = pointB.y - pointA.y
        let pdfDistance = (dx * dx + dy * dy).squareRoot()
        self.mmPerPDFUnit = pdfDistance > 0 ? (self.realDistanceMM / pdfDistance) : 0
    }

    /// Distance between the two tapped points measured in PDF units.
    var pdfDistance: Double {
        let dx = pointB.x - pointA.x
        let dy = pointB.y - pointA.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
