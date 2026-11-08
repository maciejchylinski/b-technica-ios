// Debug-only demo workspace (fictional data, no Supabase).
#if DEBUG
import Foundation
import SwiftUI

/// DEBUG-only local demo workspace.
///
/// The demo runs as a fixed local user id that is never a Supabase account, so all demo
/// data lives in its own `Documents/Users/<id>/` tree and SQLite file and can be reset
/// without touching real users. `LocalOnlyWorkspace` keeps every sync path offline for it.
enum DemoMode {
    /// Must match `demoUserId` in `demo-fixture-manifest.json`.
    static let userId = UUID(uuidString: "DE300000-B7EC-4A1C-8000-000000000001")!
    /// Opens the demo gate at launch (useful on a simulator without Supabase configuration).
    static let launchArgument = "-BTDemo"
    /// Wipes and re-seeds the demo workspace on the next prepare.
    static let resetLaunchArgument = "-BTDemoReset"

    static func isDemoUser(_ id: UUID?) -> Bool {
        id == userId
    }
}

/// One demo project as listed in the demo gate.
struct DemoProjectSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let createdDate: Date
    let drawingCount: Int
    let issueCount: Int
}

/// Drives the demo gate: seeding, project selection, reset and exit. Main-actor only.
@MainActor
final class DemoModeController: ObservableObject {
    static let shared = DemoModeController()

    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var isActive: Bool
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var projects: [DemoProjectSummary] = []
    @Published private(set) var lastReport: DemoDataSeeder.Report?
    /// Workspace of the open demo project; nil shows the demo project list.
    @Published private(set) var store: AppStore?

    private var resetOnNextPrepare: Bool

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        isActive = arguments.contains(DemoMode.launchArgument)
        resetOnNextPrepare = arguments.contains(DemoMode.resetLaunchArgument)
    }

    func enter() {
        isActive = true
    }

    func exit() {
        store = nil
        isActive = false
        phase = .idle
    }

    /// Opens the demo database and seeds it when the fixture version changed. Idempotent.
    func prepare() async {
        guard phase != .preparing else { return }
        phase = .preparing
        let force = resetOnNextPrepare
        resetOnNextPrepare = false
        do {
            let database = try AppDatabase.shared(for: DemoMode.userId)
            let report = try await Task.detached(priority: .userInitiated) {
                try DemoDataSeeder(database: database).seed(force: force)
            }.value
            lastReport = report
            projects = report.projects
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Wipes only the demo user's database rows and files, then seeds them again.
    func resetDemoData() async {
        store = nil
        KnowledgeStore.discardCachedStore(userId: DemoMode.userId)
        resetOnNextPrepare = true
        phase = .idle
        await prepare()
    }

    func open(_ project: DemoProjectSummary) {
        store = AppStore(
            userId: DemoMode.userId,
            projectId: project.id,
            projectName: project.name,
            createdDate: project.createdDate
        )
    }

    func closeProject() {
        store = nil
    }
}
#endif
