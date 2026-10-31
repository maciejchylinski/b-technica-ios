import SwiftUI

@main
struct BTechnicaApp: App {
    @StateObject private var auth = AuthStore()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-BTVerifySQLiteImport") {
            let result = JSONImportVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message,
                "firstPassCounts": result.firstPassCounts,
                "secondPassRowTotals": result.secondPassRowTotals
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-sqlite-import-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_SQLITE_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_SQLITE_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BTVerifyDrawingSQLite") {
            let result = DrawingSQLitePersistenceVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-drawing-sqlite-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_DRAWING_SQLITE_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_DRAWING_SQLITE_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BTVerifyIssueAreaSQLite") {
            let result = IssueAreaSQLitePersistenceVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-issue-area-sqlite-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_ISSUE_AREA_SQLITE_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_ISSUE_AREA_SQLITE_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppGateView()
                .environmentObject(auth)
                .tint(Theme.blue)
        }
    }
}
