import Foundation
import os.log

private let persistenceLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BTechnica",
    category: "LocalPersistence"
)

/// Opens the per-user SQLite database and runs the one-time JSON import.
enum LocalPersistenceBootstrap {
    /// Call after sign-in when `userId` is known. Failures are logged; UI is not blocked.
    @MainActor
    static func prepareIfNeeded(userId: UUID) {
        Task(priority: .utility) {
            do {
                _ = try prepareSynchronously(userId: userId)
            } catch {
                persistenceLog.error(
                    "SQLite bootstrap failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Opens DB, applies migrations, and imports JSON sources. Safe to call repeatedly.
    @MainActor
    @discardableResult
    static func prepareSynchronously(userId: UUID) throws -> AppDatabase {
        let db = try AppDatabase.shared(for: userId)
        let report = try db.importJSONSources()
        persistenceLog.info(
            "SQLite ready for user \(userId.uuidString, privacy: .public): imported=\(report.importedSourceCount) skipped=\(report.skippedSourceCount) failed=\(report.failedSourceCount)"
        )
        for source in report.sources where source.errorDescription != nil {
            persistenceLog.error(
                "JSON import failed \(source.sourceKey, privacy: .public): \(source.errorDescription ?? "", privacy: .public)"
            )
        }
        return db
    }
}
