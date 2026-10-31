import Foundation
import GRDB

/// Local SQLite database (GRDB) for one signed-in user.
///
/// Path: `Documents/Users/<userId>/btechnica.sqlite`
/// Drawing folders, drawings, issues, areas, and issue photo metadata are authoritative
/// here after import. JSON remains a read-only recovery source for those entities;
/// PDF/photo files stay on disk.
final class AppDatabase: @unchecked Sendable {
    let userId: UUID
    let dbQueue: DatabaseQueue
    let rootURL: URL

    /// Shared instances keyed by user id (main-actor access from UI bootstrap).
    @MainActor
    private static var cache: [UUID: AppDatabase] = [:]

    private init(userId: UUID, dbQueue: DatabaseQueue, rootURL: URL) {
        self.userId = userId
        self.dbQueue = dbQueue
        self.rootURL = rootURL
    }

    /// Opens (or returns cached) the per-user SQLite database and applies migrations.
    @MainActor
    static func shared(for userId: UUID) throws -> AppDatabase {
        if let existing = cache[userId] { return existing }
        let opened = try open(userId: userId)
        cache[userId] = opened
        return opened
    }

    @MainActor
    static func dropCached(for userId: UUID) {
        cache.removeValue(forKey: userId)
    }

    static func userRootURL(for userId: UUID, fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent(userId.uuidString, isDirectory: true)
    }

    static func databaseURL(for userId: UUID, fileManager: FileManager = .default) -> URL {
        userRootURL(for: userId, fileManager: fileManager)
            .appendingPathComponent("btechnica.sqlite")
    }

    /// Opens a database at the standard per-user path (creates directories as needed).
    static func open(userId: UUID, fileManager: FileManager = .default) throws -> AppDatabase {
        let root = userRootURL(for: userId, fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("btechnica.sqlite")
        return try open(userId: userId, at: url, rootURL: root)
    }

    /// Opens a database at an explicit path (used by migration verification on a data copy).
    static func open(userId: UUID, at databaseURL: URL, rootURL: URL) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        let database = AppDatabase(userId: userId, dbQueue: dbQueue, rootURL: rootURL)
        try database.migrator.migrate(dbQueue)
        return database
    }

    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Avoid erasing in production; DEBUG-only can help during schema iteration.
        // migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_foundation") { db in
            try Self.createV1Schema(db)
        }

        return migrator
    }

    /// Runs idempotent JSON → SQLite import for userdata + all project workspaces under this user.
    @discardableResult
    func importJSONSources(fileManager: FileManager = .default) throws -> JSONImportReport {
        let importer = JSONToSQLiteImporter(database: self, fileManager: fileManager)
        return try importer.importAll()
    }
}
