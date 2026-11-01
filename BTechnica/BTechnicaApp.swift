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
        if ProcessInfo.processInfo.arguments.contains("-BTVerifyUserSharedSQLite") {
            let result = UserSharedSQLitePersistenceVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-user-shared-sqlite-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_USER_SHARED_SQLITE_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_USER_SHARED_SQLITE_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BTVerifySyncOutbox") {
            let result = SyncOutboxVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-sync-outbox-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_SYNC_OUTBOX_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_SYNC_OUTBOX_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BTVerifyFolderCreateSync") {
            let result = FolderCreateSyncVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-folder-create-sync-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_FOLDER_CREATE_SYNC_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_FOLDER_CREATE_SYNC_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BTVerifyLiveFolderSync") {
            let result = LiveFolderSyncVerification.run()
            let payload: [String: Any] = [
                "passed": result.passed,
                "message": result.message
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bt-live-folder-sync-verify.json")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                fputs("BT_LIVE_FOLDER_SYNC_VERIFY \(text)\n", stderr)
            } else {
                fputs("BT_LIVE_FOLDER_SYNC_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
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
