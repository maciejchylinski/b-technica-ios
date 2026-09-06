import Foundation

/// Root persisted document for the whole app. Everything is stored in a single
/// JSON file for this first slice — simple, offline-first, and easy to reason
/// about. If/when the data grows this can be swapped for SwiftData without
/// changing the feature code that talks to `AppStore`.
struct AppData: Codable {
    var project: Project
    var drawings: [Drawing]
    var issues: [Issue]
    var equipment: [EquipmentItem]

    init(project: Project,
         drawings: [Drawing] = [],
         issues: [Issue] = [],
         equipment: [EquipmentItem] = []) {
        self.project = project
        self.drawings = drawings
        self.issues = issues
        self.equipment = equipment
    }
}
