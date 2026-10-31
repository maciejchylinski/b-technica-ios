import Foundation

/// Summary of a JSON → SQLite import pass (safe to log; no secrets).
struct JSONImportReport: Equatable {
    struct SourceResult: Equatable {
        var sourceKey: String
        var skippedAlreadyImported: Bool
        var counts: [String: Int]
        var errorDescription: String?
    }

    var sources: [SourceResult] = []

    var importedSourceCount: Int {
        sources.filter { !$0.skippedAlreadyImported && $0.errorDescription == nil }.count
    }

    var skippedSourceCount: Int {
        sources.filter(\.skippedAlreadyImported).count
    }

    var failedSourceCount: Int {
        sources.filter { $0.errorDescription != nil }.count
    }
}
