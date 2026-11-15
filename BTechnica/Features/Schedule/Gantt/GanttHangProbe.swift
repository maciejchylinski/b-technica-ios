#if DEBUG
import GRDB
import SwiftUI
import UIKit

/// Hosts the real Schedule Gantt with the demo project's snapshot and measures
/// whether layout stays bounded to the viewport or expands to the full timeline.
/// Launch: `-BTVerifyGanttHang` (DEBUG). Exit 0 = bounded & responsive.
enum GanttHangProbe {
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifyGanttHang") else { return }
        let result = run()
        fputs("BT_GANTT_HANG_PROBE \(result)\n", stderr)
        exit(result.hasPrefix("passed=true") ? 0 : 1)
    }

    @MainActor
    private static func run() -> String {
        var lines: [String] = []
        do {
            let userId = DemoMode.userId
            let database = try AppDatabase.shared(for: userId)
            // Ensure the demo workspace exists (idempotent).
            _ = try DemoDataSeeder(database: database).seed(force: false)
            let projectRow = try database.dbQueue.read { db -> (UUID, String, Date)? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id, name, created_at FROM projects WHERE name LIKE ? ORDER BY name LIMIT 1",
                    arguments: ["%Zielone Tarasy%"]
                ),
                let id = UUID(uuidString: row["id"]),
                let created = SQLiteDateCoding.date(from: row["created_at"])
                else { return nil }
                return (id, row["name"], created)
            }
            guard let projectRow else { return "passed=false msg=no demo project" }
            let project = Project(id: projectRow.0, name: projectRow.1, createdDate: projectRow.2)
            let snapshot = try database.fetchScheduleSnapshot(projectId: project.id)
            lines.append("tasks=\(snapshot.tasks.count) deps=\(snapshot.dependencies.count)")

            let today = CalendarDay.today()
            let layout = GanttLayout(snapshot: snapshot, collapsed: [], today: today)
            let metrics = GanttMetrics.make(scale: .week, isRegularWidth: false)
            let content = metrics.contentSize(for: layout)
            lines.append("dayCount=\(layout.dayCount) contentSize=\(Int(content.width))x\(Int(content.height))")

            // Probe A: Gantt alone (viewport-bounded host).
            let ganttStore = ScheduleStore(database: database, project: project)
            let ganttHost = UIHostingController(rootView:
                ScheduleGanttView(onOpenTask: { _ in })
                    .environmentObject(ganttStore)
                    .frame(width: 390, height: 640)
            )
            let ganttWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
            ganttWindow.rootViewController = ganttHost
            ganttWindow.makeKeyAndVisible()
            let clock = ContinuousClock()
            var started = clock.now
            ganttHost.view.layoutIfNeeded()
            for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            lines.append("ganttAloneMs=\((clock.now - started).formatted(.units(allowed: [.milliseconds], width: .abbreviated))) host=\(Int(ganttHost.view.bounds.width))x\(Int(ganttHost.view.bounds.height))")
            ganttWindow.isHidden = true

            // Probe B: ScheduleHomeView on iPhone size class (default section = Tasks).
            // Before the environmentObject fix this fatalError'd; it must now lay out quickly.
            let home = ScheduleHomeView(userId: userId, project: project, contractorNames: [])
                .environment(\.horizontalSizeClass, .compact)
                .frame(width: 390, height: 844)
            let homeHost = UIHostingController(rootView: home)
            let homeWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            homeWindow.rootViewController = homeHost
            homeWindow.makeKeyAndVisible()

            let layoutBudget = Duration.seconds(2)
            started = clock.now
            homeHost.view.setNeedsLayout()
            homeHost.view.layoutIfNeeded()
            for _ in 0..<30 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if clock.now - started > layoutBudget {
                    lines.append("FAILED: ScheduleHomeView(compact) layout exceeded \(layoutBudget)")
                    return (["passed=false"] + lines).joined(separator: " | ")
                }
            }
            let homeElapsed = clock.now - started
            lines.append("homeTasksMs=\(homeElapsed.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))")
            lines.append("homeHost=\(Int(homeHost.view.bounds.width))x\(Int(homeHost.view.bounds.height))")

            // Probe C: Gantt chart for the same 23-task demo snapshot stays viewport-bounded.
            let ganttOk = ganttHost.view.bounds.width <= 420
                && content.width >= 1000
                && layout.dayCount > 400
                && snapshot.tasks.count == 23
                && snapshot.dependencies.count == 20
            let homeOk = homeHost.view.bounds.width <= 420 && homeElapsed < Duration.milliseconds(1500)

            if ganttOk && homeOk {
                lines.insert("passed=true", at: 0)
            } else {
                lines.insert("passed=false", at: 0)
                if !ganttOk { lines.append("ROOT: gantt alone failed bounds/data checks") }
                if !homeOk { lines.append("ROOT: ScheduleHomeView compact path failed") }
            }
            homeWindow.isHidden = true
            return lines.joined(separator: " | ")
        } catch {
            return "passed=false msg=\(error)"
        }
    }
}
#endif
