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
    var name: String
    /// File name relative to Documents/Drawings, e.g. "<uuid>.pdf".
    var fileName: String
    var pageCount: Int
    var createdDate: Date
    /// One calibration entry per calibrated page. A drawing counts as
    /// "Calibrated" as soon as at least one page has a calibration.
    var calibrations: [PageCalibration]

    init(id: UUID = UUID(),
         projectId: UUID,
         name: String,
         fileName: String,
         pageCount: Int,
         createdDate: Date = Date(),
         calibrations: [PageCalibration] = []) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.fileName = fileName
        self.pageCount = pageCount
        self.createdDate = createdDate
        self.calibrations = calibrations
    }

    var isCalibrated: Bool { !calibrations.isEmpty }

    var calibrationStatusText: String { isCalibrated ? "Calibrated" : "Not calibrated" }

    func calibration(forPage pageIndex: Int) -> PageCalibration? {
        calibrations.first { $0.pageIndex == pageIndex }
    }
}
