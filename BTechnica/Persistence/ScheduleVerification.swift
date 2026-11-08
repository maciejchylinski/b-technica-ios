// Debug-only verification harness (launch-argument driven from BTechnicaApp).
#if DEBUG
import Foundation
import GRDB
import SwiftUI

/// Focused checks for the construction schedule module: calendar-day handling,
/// date validation, dependency cycles, and SQLite persistence / isolation.
/// Run with launch argument `-BTVerifySchedule` (DEBUG).
enum ScheduleVerification {
    struct Result: Equatable {
        var passed: Bool
        var message: String
        var checks: [String]
    }

    private struct Failure: Error {
        var message: String
    }

    /// Verification-only launch: exits after reporting so the signed-in user's real
    /// database is never opened or migrated by a test run.
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifySchedule") else { return }
        let result = run()
        defer { exit(result.passed ? 0 : 1) }
        let payload: [String: Any] = [
            "passed": result.passed,
            "message": result.message,
            "checks": result.checks
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bt-schedule-verify.json")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            fputs("BT_SCHEDULE_VERIFY \(text)\n", stderr)
        } else {
            fputs("BT_SCHEDULE_VERIFY passed=\(result.passed) msg=\(result.message)\n", stderr)
        }
        renderGanttSnapshots()
    }

    /// Writes Gantt PNGs (iPhone + iPad metrics, week + month) for visual review.
    @MainActor
    private static func renderGanttSnapshots() {
        let today = CalendarDay.today()
        let layout = GanttLayout(snapshot: sampleSnapshot(today: today), collapsed: [], today: today)
        let variants: [(name: String, size: CGSize, regular: Bool, scale: GanttScale)] = [
            ("iphone-week", CGSize(width: 393, height: 640), false, .week),
            ("ipad-week", CGSize(width: 1024, height: 700), true, .week),
            ("ipad-month", CGSize(width: 1024, height: 700), true, .month)
        ]
        for variant in variants {
            let metrics = GanttMetrics.make(scale: variant.scale, isRegularWidth: variant.regular)
            let renderer = GanttRenderer(layout: layout, metrics: metrics, scale: variant.scale, showsLinks: true)
            let offset = CGPoint(
                x: max(0, metrics.scrollX(for: today.ordinal, in: layout, viewportWidth: variant.size.width, fraction: 0.25)),
                y: 0
            )
            let view = Canvas { ctx, size in renderer.draw(in: &ctx, size: size, offset: offset) }
                .frame(width: variant.size.width, height: variant.size.height)
            let image = ImageRenderer(content: view)
            image.scale = 2
            if let data = image.uiImage?.pngData() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("bt-gantt-\(variant.name).png")
                try? data.write(to: url)
                fputs("BT_SCHEDULE_GANTT_SNAPSHOT \(url.path)\n", stderr)
            }
        }
    }

    private static func sampleSnapshot(today: CalendarDay) -> ScheduleSnapshot {
        let projectId = UUID(), scheduleId = UUID()
        let now = Date()
        let phaseSpecs = [("Site setup", "#7A8794"), ("Substructure", "#2E9E5B"),
                          ("Superstructure", "#1C7AE6"), ("Envelope & MEP", "#E08A1E")]
        let phases = phaseSpecs.enumerated().map { index, spec in
            SchedulePhase(id: UUID(), projectId: projectId, scheduleId: scheduleId, name: spec.0,
                          colorHex: spec.1, sortOrder: index, createdAt: now, updatedAt: now)
        }
        var tasks: [ScheduleTask] = []
        var dependencies: [ScheduleDependency] = []
        var cursor = today.adding(days: -24)
        let titles = ["Mobilisation and hoarding", "Temporary services", "Excavation to formation level",
                      "Piling", "Pile caps and ground beams", "Ground floor slab", "Level 1 columns",
                      "Level 1 slab pour", "Level 2 columns and core walls", "Roof structure",
                      "Façade brackets", "Curtain wall installation", "MEP first fix", "Commissioning"]
        for (index, title) in titles.enumerated() {
            let phase = phases[min(phases.count - 1, index / 4)]
            let duration = [5, 4, 9, 6, 8, 5, 6, 3, 10, 7, 4, 15, 12, 6][index]
            var task = sampleTask(title: title, start: cursor.isoString, finish: cursor.adding(days: duration - 1).isoString)
            task.projectId = projectId
            task.scheduleId = scheduleId
            task.phaseId = phase.id
            task.sortOrder = index
            let finished = task.finishDay < today
            task.progress = finished ? (index == 4 ? 70 : 100) : (task.startDay <= today ? 40 : 0)
            task.status = finished ? (index == 4 ? .inProgress : .completed) : (task.startDay <= today ? .inProgress : .planned)
            if index == 9 { task.status = .delayed }
            if let previous = tasks.last, index % 2 == 1 {
                dependencies.append(dependency(projectId, scheduleId, from: previous.id, to: task.id))
            }
            tasks.append(task)
            cursor = cursor.adding(days: index % 3 == 0 ? duration - 2 : duration)
            if index == 7 || index == 13 {
                var milestone = sampleTask(title: index == 7 ? "Structure topped out" : "Practical completion",
                                           start: cursor.isoString, finish: cursor.isoString)
                milestone.kind = .milestone
                milestone.projectId = projectId
                milestone.scheduleId = scheduleId
                milestone.phaseId = phase.id
                milestone.sortOrder = index + 100
                dependencies.append(dependency(projectId, scheduleId, from: task.id, to: milestone.id))
                tasks.append(milestone)
            }
        }
        return ScheduleSnapshot(
            schedule: ConstructionSchedule(id: scheduleId, projectId: projectId, name: "Sample",
                                           details: "", createdAt: now, updatedAt: now),
            phases: phases,
            tasks: tasks,
            dependencies: dependencies
        )
    }

    static func run() -> Result {
        var checks: [String] = []
        do {
            try calendarDayChecks(&checks)
            try validationChecks(&checks)
            try cycleChecks(&checks)
            try persistenceChecks(&checks)
            return Result(passed: true, message: "All \(checks.count) schedule checks passed.", checks: checks)
        } catch let failure as Failure {
            return Result(passed: false, message: failure.message, checks: checks)
        } catch {
            return Result(passed: false, message: "Threw: \(error)", checks: checks)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: "FAILED: \(message)") }
    }

    private static func expectThrows(
        _ expected: ScheduleValidationError,
        _ message: String,
        _ work: () throws -> Void
    ) throws {
        do {
            try work()
        } catch let error as ScheduleValidationError {
            try expect(error == expected, "\(message) — got \(error), expected \(expected)")
            return
        }
        throw Failure(message: "FAILED: \(message) — no error thrown")
    }

    private static func expectDatabaseError(_ message: String, _ work: () throws -> Void) throws {
        do {
            try work()
        } catch is DatabaseError {
            return
        }
        throw Failure(message: "FAILED: \(message) — SQLite accepted invalid row")
    }

    // MARK: - Calendar days

    private static func calendarDayChecks(_ checks: inout [String]) throws {
        let leap = CalendarDay(year: 2024, month: 2, day: 28)!
        try expect(leap.adding(days: 1).isoString == "2024-02-29", "leap day")
        try expect(leap.adding(days: 2).isoString == "2024-03-01", "after leap day")
        try expect(CalendarDay(year: 2023, month: 2, day: 29) == nil, "reject 2023-02-29")
        try expect(CalendarDay(isoString: "2026-13-01") == nil, "reject month 13")
        try expect(CalendarDay(isoString: "2026-1-01") == nil, "reject non-padded")
        try expect(CalendarDay(isoString: "2026-11-02")?.isoWeekday == 1, "2026-11-02 is Monday")
        try expect(CalendarDay(isoString: "2026-11-02")?.isoWeekOfYear == 45, "ISO week 45")
        try expect(CalendarDay(isoString: "2027-01-01")?.isoWeekOfYear == 53, "2027-01-01 in ISO week 53")
        try expect(CalendarDay(ordinal: 0).isoString == "1970-01-01", "epoch ordinal")
        for ordinal in stride(from: -800_000, through: 800_000, by: 997) {
            try expect(CalendarDay(ordinal: ordinal).ordinal == ordinal, "ordinal round trip \(ordinal)")
        }
        let spanStart = CalendarDay(isoString: "2026-03-01")!
        let spanEnd = CalendarDay(isoString: "2026-11-30")!
        try expect(spanStart.days(to: spanEnd) == 274, "day span across DST")
        checks.append("calendar arithmetic (leap years, ISO weeks, ordinals)")

        // Local-noon round trip must not shift the day in extreme or DST zones.
        let zones = ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/Warsaw", "America/Los_Angeles", "Australia/Lord_Howe"]
        let days = ["2026-03-08", "2026-03-29", "2026-10-25", "2026-11-01", "2026-12-31", "2024-02-29"]
        for zoneId in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zoneId)!
            for raw in days {
                let day = CalendarDay(isoString: raw)!
                let roundTrip = CalendarDay(day.date(calendar: calendar), calendar: calendar)
                try expect(roundTrip == day, "\(raw) round trip in \(zoneId) gave \(roundTrip)")
            }
        }
        // Same instant shows the local wall date, not the UTC date.
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let instant = SQLiteDateCoding.date(from: "2026-11-02T20:00:00Z")!
        try expect(CalendarDay(instant, calendar: auckland).isoString == "2026-11-03", "local wall date")

        let encoded = try JSONEncoder().encode(["d": CalendarDay(isoString: "2026-11-02")!])
        try expect(String(data: encoded, encoding: .utf8) == #"{"d":"2026-11-02"}"#, "Codable as yyyy-MM-dd")
        checks.append("no time-zone day shifts across \(zones.count) zones / DST")
    }

    // MARK: - Validation

    private static func validationChecks(_ checks: inout [String]) throws {
        let base = sampleTask(title: "  Pour slab  ", start: "2026-11-10", finish: "2026-11-12")
        let normalized = try ScheduleRules.normalized(base)
        try expect(normalized.title == "Pour slab", "title trimmed")
        try expect(normalized.durationDays == 3, "inclusive duration")

        try expectThrows(.finishBeforeStart, "finish before start rejected") {
            _ = try ScheduleRules.normalized(sampleTask(title: "X", start: "2026-11-12", finish: "2026-11-10"))
        }
        try expectThrows(.emptyTaskTitle, "blank title rejected") {
            _ = try ScheduleRules.normalized(sampleTask(title: "   ", start: "2026-11-10", finish: "2026-11-10"))
        }
        let oneDay = try ScheduleRules.normalized(sampleTask(title: "Inspect", start: "2026-11-10", finish: "2026-11-10"))
        try expect(oneDay.durationDays == 1, "same-day task is 1 day")

        var milestone = sampleTask(title: "Handover", start: "2026-12-01", finish: "2026-12-20")
        milestone.kind = .milestone
        let normalizedMilestone = try ScheduleRules.normalized(milestone)
        try expect(normalizedMilestone.finishDay == normalizedMilestone.startDay, "milestone collapses to one day")
        try expect(normalizedMilestone.durationDays == 0, "milestone duration 0")

        var completed = base
        completed.status = .completed
        completed.progress = 40
        try expect(try ScheduleRules.normalized(completed).progress == 100, "completed ⇒ 100 %")
        var over = base
        over.progress = 140
        try expect(try ScheduleRules.normalized(over).progress == 100, "progress clamped")

        try expect(ScheduleRules.applyingProgress(100, to: base).status == .completed, "100 % completes")
        try expect(ScheduleRules.applyingProgress(30, to: base).status == .inProgress, "progress starts task")
        let reopened = ScheduleRules.applyingStatus(.inProgress, to: ScheduleRules.applyingStatus(.completed, to: base))
        try expect(reopened.progress < 100 && reopened.status == .inProgress, "reopen drops below 100 %")

        let today = CalendarDay(isoString: "2026-11-15")!
        try expect(base.isOverdue(today: today), "past finish ⇒ overdue")
        try expect(!ScheduleRules.applyingStatus(.completed, to: base).isBehind(today: today), "completed never behind")

        let pred = sampleTask(title: "A", start: "2026-11-01", finish: "2026-11-05")
        let okSucc = sampleTask(title: "B", start: "2026-11-06", finish: "2026-11-08")
        let badSucc = sampleTask(title: "C", start: "2026-11-05", finish: "2026-11-08")
        try expect(!ScheduleRules.violatesFinishToStart(predecessor: pred, successor: okSucc), "FS next day ok")
        try expect(ScheduleRules.violatesFinishToStart(predecessor: pred, successor: badSucc), "FS overlap flagged")
        checks.append("date range, milestone, progress and finish-to-start validation")
    }

    // MARK: - Cycles

    private static func cycleChecks(_ checks: inout [String]) throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        typealias E = ScheduleRules.Edge
        let chain = [E(predecessor: a, successor: b), E(predecessor: b, successor: c)]
        try expect(ScheduleRules.wouldCreateCycle(adding: E(predecessor: c, successor: a), to: chain), "A→B→C→A cycle")
        try expect(ScheduleRules.wouldCreateCycle(adding: E(predecessor: a, successor: a), to: []), "self loop")
        try expect(!ScheduleRules.wouldCreateCycle(adding: E(predecessor: a, successor: c), to: chain), "shortcut A→C ok")
        let diamond = chain + [E(predecessor: a, successor: d)]
        try expect(!ScheduleRules.wouldCreateCycle(adding: E(predecessor: d, successor: c), to: diamond), "diamond ok")
        try expect(ScheduleRules.blockedPredecessors(for: a, edges: chain) == [a, b, c], "downstream blocked")

        try expectThrows(.circularDependency, "replace predecessors with cycle") {
            try ScheduleRules.validatePredecessors([c], of: a, existing: chain)
        }
        try expectThrows(.selfDependency, "self predecessor") {
            try ScheduleRules.validatePredecessors([a], of: a, existing: [])
        }
        try expectThrows(.duplicateDependency, "duplicate predecessor") {
            try ScheduleRules.validatePredecessors([a, a], of: b, existing: [])
        }
        // Replacing B's predecessors removes A→B first, so C→B would still cycle (B→C).
        try expectThrows(.circularDependency, "replace keeps outgoing edges") {
            try ScheduleRules.validatePredecessors([c], of: b, existing: chain)
        }
        try ScheduleRules.validatePredecessors([d], of: b, existing: chain)
        checks.append("circular dependency detection")
    }

    // MARK: - Persistence

    private static func persistenceChecks(_ checks: inout [String]) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-schedule-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let userId = UUID()
        let projectA = Project(id: UUID(), name: "Tower A", createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        let projectB = Project(id: UUID(), name: "Tower B", createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        let db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.ensureProject(projectA)
        try db.ensureProject(projectB)

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let scheduleA = ConstructionSchedule(id: UUID(), projectId: projectA.id, name: "Main", details: "", createdAt: now, updatedAt: now)
        let scheduleB = ConstructionSchedule(id: UUID(), projectId: projectB.id, name: "Main B", details: "", createdAt: now, updatedAt: now)
        try db.createSchedule(scheduleA)
        try db.createSchedule(scheduleB)
        try expectThrows(.scheduleAlreadyExists, "one schedule per project") {
            try db.createSchedule(ConstructionSchedule(id: UUID(), projectId: projectA.id, name: "Dup", details: "", createdAt: now, updatedAt: now))
        }

        let phase = SchedulePhase(id: UUID(), projectId: projectA.id, scheduleId: scheduleA.id, name: "Foundations",
                                  colorHex: "#2E9E5B", sortOrder: 0, createdAt: now, updatedAt: now)
        let phase2 = SchedulePhase(id: UUID(), projectId: projectA.id, scheduleId: scheduleA.id, name: "Frame",
                                   colorHex: "#1C7AE6", sortOrder: 1, createdAt: now, updatedAt: now)
        try db.savePhase(phase)
        try db.savePhase(phase2)

        var t1 = sampleTask(title: "Excavate", start: "2026-11-02", finish: "2026-11-06")
        t1.projectId = projectA.id; t1.scheduleId = scheduleA.id; t1.phaseId = phase.id; t1.sortOrder = 0
        t1.responsibleName = "Acme Earthworks"
        t1.responsibleContactId = UUID()
        var t2 = sampleTask(title: "Footings", start: "2026-11-09", finish: "2026-11-13")
        t2.projectId = projectA.id; t2.scheduleId = scheduleA.id; t2.phaseId = phase.id; t2.sortOrder = 1
        var t3 = sampleTask(title: "Columns", start: "2026-11-16", finish: "2026-11-27")
        t3.projectId = projectA.id; t3.scheduleId = scheduleA.id; t3.phaseId = phase2.id
        var m1 = sampleTask(title: "Frame complete", start: "2026-11-27", finish: "2026-11-27")
        m1.kind = .milestone
        m1.projectId = projectA.id; m1.scheduleId = scheduleA.id; m1.phaseId = phase2.id; m1.sortOrder = 1

        try db.saveTask(t1)
        try db.saveTask(t2, predecessorIds: [t1.id])
        try db.saveTask(t3, predecessorIds: [t2.id])
        try db.saveTask(m1, predecessorIds: [t3.id])

        // Reopen: everything survives with exact calendar days.
        let reopened = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        var snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.schedule?.id == scheduleA.id, "schedule persisted")
        try expect(snap.phases.map(\.name) == ["Foundations", "Frame"], "phases ordered")
        try expect(snap.tasks.count == 4 && snap.dependencies.count == 3, "tasks + deps persisted")
        guard let loaded1 = snap.tasks.first(where: { $0.id == t1.id }) else {
            throw Failure(message: "FAILED: task missing after reopen")
        }
        try expect(loaded1.startDay.isoString == "2026-11-02" && loaded1.finishDay.isoString == "2026-11-06", "days exact")
        try expect(loaded1.responsibleName == "Acme Earthworks" && loaded1.responsibleContactId == t1.responsibleContactId, "responsibility persisted")
        try expect(snap.tasks.first { $0.id == m1.id }?.kind == .milestone, "milestone persisted")
        checks.append("task / phase / dependency persistence across reopen")

        // Cycle through persistence is rejected and rolled back.
        var t1Edited = t1
        t1Edited.title = "Excavate (edited)"
        try expectThrows(.circularDependency, "persisted cycle rejected") {
            try reopened.saveTask(t1Edited, predecessorIds: [m1.id])
        }
        snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.tasks.first { $0.id == t1.id }?.title == "Excavate", "failed save rolled back")
        try expect(snap.dependencies.count == 3, "deps unchanged after rollback")
        try expectThrows(.circularDependency, "addDependency cycle rejected") {
            try reopened.addDependency(dependency(projectA.id, scheduleA.id, from: m1.id, to: t2.id))
        }
        try expectThrows(.duplicateDependency, "duplicate dep rejected") {
            try reopened.addDependency(dependency(projectA.id, scheduleA.id, from: t1.id, to: t2.id))
        }
        try expectThrows(.finishBeforeStart, "invalid range rejected on save") {
            var bad = t2
            bad.finishDay = CalendarDay(isoString: "2026-11-01")!
            try reopened.saveTask(bad)
        }
        checks.append("transactional rollback on cycle / invalid dates")

        // Database-level guards (bypassing Swift validation).
        try expectDatabaseError("CHECK finish >= start") {
            try reopened.dbQueue.write { db in
                try db.execute(sql: "UPDATE schedule_tasks SET finish_date = '2026-10-01' WHERE id = ?", arguments: [t2.id.uuidString])
            }
        }
        try expectDatabaseError("CHECK progress range") {
            try reopened.dbQueue.write { db in
                try db.execute(sql: "UPDATE schedule_tasks SET progress = 101 WHERE id = ?", arguments: [t2.id.uuidString])
            }
        }
        try expectDatabaseError("FK: task cannot point at other project's schedule") {
            try reopened.dbQueue.write { db in
                try db.execute(sql: "UPDATE schedule_tasks SET schedule_id = ? WHERE id = ?",
                               arguments: [scheduleB.id.uuidString, t2.id.uuidString])
            }
        }
        checks.append("SQLite CHECK / composite FK guards")

        // Cross-project isolation through the API.
        var foreign = t3
        foreign.id = UUID()
        foreign.projectId = projectB.id
        foreign.scheduleId = scheduleB.id
        try expectThrows(.phaseNotInSchedule, "phase from other project rejected") {
            try reopened.saveTask(foreign)
        }
        var hijack = t3
        hijack.projectId = projectB.id
        hijack.scheduleId = scheduleB.id
        hijack.phaseId = nil
        try expectThrows(.taskNotInSchedule, "existing task cannot move to other project") {
            try reopened.saveTask(hijack)
        }
        var bTask = sampleTask(title: "B task", start: "2026-11-02", finish: "2026-11-03")
        bTask.projectId = projectB.id; bTask.scheduleId = scheduleB.id
        try reopened.saveTask(bTask)
        try expectThrows(.taskNotInSchedule, "cross-schedule dependency rejected") {
            try reopened.addDependency(dependency(projectA.id, scheduleA.id, from: bTask.id, to: t1.id))
        }
        try expectThrows(.taskNotInSchedule, "cross-schedule predecessor rejected") {
            try reopened.saveTask(t1, predecessorIds: [bTask.id])
        }
        reopened.deleteTaskSafely(id: bTask.id, projectId: projectA.id)
        let snapB = try reopened.fetchScheduleSnapshot(projectId: projectB.id)
        try expect(snapB.tasks.map(\.id) == [bTask.id], "delete scoped by project")
        try expect(try reopened.fetchScheduleSnapshot(projectId: projectA.id).tasks.count == 4, "project A untouched")
        checks.append("no cross-project / cross-schedule mixing")

        // Reorder + move between phases.
        try reopened.reorderTasks([t2.id, t1.id], scheduleId: scheduleA.id, projectId: projectA.id, at: now)
        snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.tasks.filter { $0.phaseId == phase.id }.map(\.id) == [t2.id, t1.id], "reorder persisted")
        try reopened.reorderPhases([phase2.id, phase.id], scheduleId: scheduleA.id, projectId: projectA.id, at: now)
        snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.phases.map(\.id) == [phase2.id, phase.id], "phase reorder persisted")
        checks.append("reorder tasks and phases")

        // Deleting a task drops its dependencies; deleting a phase drops its tasks.
        try reopened.deleteTask(id: t3.id, projectId: projectA.id)
        snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.dependencies.count == 1, "task delete cascades deps")
        try reopened.deletePhase(id: phase.id, projectId: projectA.id)
        snap = try reopened.fetchScheduleSnapshot(projectId: projectA.id)
        try expect(snap.tasks.map(\.id) == [m1.id] && snap.dependencies.isEmpty, "phase delete cascades tasks")
        try reopened.deleteSchedule(id: scheduleA.id, projectId: projectA.id)
        try expect(try reopened.fetchScheduleSnapshot(projectId: projectA.id) == .empty, "schedule delete cascades")
        let remaining = try reopened.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schedule_tasks WHERE project_id = ?", arguments: [projectA.id.uuidString])
        }
        try expect(remaining == 0, "no orphan task rows")
        try expect(try reopened.fetchScheduleSnapshot(projectId: projectB.id).tasks.count == 1, "project B unaffected")
        checks.append("cascading deletes")

        try largeScheduleCheck(db: reopened, project: projectA, now: now, checks: &checks)
    }

    /// A realistic-size schedule (600 tasks, chained deps) persists and loads quickly.
    private static func largeScheduleCheck(db: AppDatabase, project: Project, now: Date, checks: inout [String]) throws {
        let schedule = ConstructionSchedule(id: UUID(), projectId: project.id, name: "Large", details: "", createdAt: now, updatedAt: now)
        try db.createSchedule(schedule)
        let start = CalendarDay(isoString: "2026-01-05")!
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var previous: UUID?
            for p in 0..<20 {
                let phase = SchedulePhase(id: UUID(), projectId: project.id, scheduleId: schedule.id, name: "Phase \(p + 1)",
                                          colorHex: "#1C7AE6", sortOrder: p, createdAt: now, updatedAt: now)
                try db.savePhase(phase)
                for i in 0..<30 {
                    var task = sampleTask(title: "Task \(p)-\(i)", start: "2026-01-05", finish: "2026-01-05")
                    task.projectId = project.id
                    task.scheduleId = schedule.id
                    task.phaseId = phase.id
                    task.sortOrder = i
                    task.startDay = start.adding(days: p * 20 + i)
                    task.finishDay = task.startDay.adding(days: 3)
                    try db.saveTask(task, predecessorIds: i % 3 == 0 ? previous.map { [$0] } : nil)
                    previous = task.id
                }
            }
        }
        let loadStart = clock.now
        let snap = try db.fetchScheduleSnapshot(projectId: project.id)
        let loadTime = clock.now - loadStart
        let layout = GanttLayout(snapshot: snap, collapsed: [], today: start)
        try expect(snap.tasks.count == 600 && layout.rows.count == 620, "600 tasks loaded and laid out")
        checks.append("600-task schedule: write \(elapsed.formatted(.units(allowed: [.milliseconds]))), load \(loadTime.formatted(.units(allowed: [.milliseconds])))")
    }

    // MARK: - Fixtures

    private static func sampleTask(title: String, start: String, finish: String) -> ScheduleTask {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        return ScheduleTask(
            id: UUID(),
            projectId: UUID(),
            scheduleId: UUID(),
            phaseId: nil,
            kind: .task,
            title: title,
            details: "",
            startDay: CalendarDay(isoString: start)!,
            finishDay: CalendarDay(isoString: finish)!,
            progress: 0,
            status: .planned,
            responsibleName: nil,
            responsibleContactId: nil,
            notes: "",
            sortOrder: 0,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func dependency(_ projectId: UUID, _ scheduleId: UUID, from: UUID, to: UUID) -> ScheduleDependency {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        return ScheduleDependency(id: UUID(), projectId: projectId, scheduleId: scheduleId,
                                  predecessorId: from, successorId: to, type: .finishToStart,
                                  createdAt: now, updatedAt: now)
    }
}

private extension AppDatabase {
    /// Deleting with the wrong project id must be a no-op.
    func deleteTaskSafely(id: UUID, projectId: UUID) {
        try? deleteTask(id: id, projectId: projectId)
    }
}
#endif
