import SwiftUI

enum ScheduleStyle {
    static func color(hex: String) -> Color {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            return Theme.blue
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static let behind = Color.red
    static let conflict = Color.orange

    static func statusColor(_ status: ScheduleTaskStatus) -> Color {
        switch status {
        case .planned: return .secondary
        case .inProgress: return Theme.blue
        case .completed: return .green
        case .delayed: return .red
        }
    }
}

/// Display formatting for calendar days (rendered at local noon, so no day shift).
enum ScheduleDateFormat {
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    static let monthNames: [String] = DateFormatter().standaloneMonthSymbols
    static let shortMonthNames: [String] = DateFormatter().shortStandaloneMonthSymbols

    static func short(_ day: CalendarDay) -> String { shortFormatter.string(from: day.date()) }
    static func medium(_ day: CalendarDay) -> String { mediumFormatter.string(from: day.date()) }
    static func weekday(_ day: CalendarDay) -> String { weekdayFormatter.string(from: day.date()) }

    static func range(_ task: ScheduleTask) -> String {
        task.isMilestone ? short(task.startDay) : "\(short(task.startDay)) – \(short(task.finishDay))"
    }

    static func duration(_ task: ScheduleTask) -> String {
        task.isMilestone ? "Milestone" : (task.durationDays == 1 ? "1 day" : "\(task.durationDays) days")
    }

    /// "Today", "Tomorrow", "in 5 days", "3 days ago".
    static func relative(_ day: CalendarDay, today: CalendarDay) -> String {
        let delta = today.days(to: day)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...: return "in \(delta) days"
        default: return "\(-delta) days ago"
        }
    }
}

struct ScheduleStatusBadge: View {
    let task: ScheduleTask
    let today: CalendarDay

    var body: some View {
        let overdue = task.isOverdue(today: today) && task.status != .delayed
        let label = overdue ? "Overdue" : task.status.label
        let color = overdue ? ScheduleStyle.behind : ScheduleStyle.statusColor(task.status)
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status \(label)")
    }
}

struct ScheduleProgressBar: View {
    let progress: Int
    var tint: Color = Theme.blue
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, progress))) / 100)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress \(progress) percent")
    }
}

/// Diamond glyph used for milestones in lists.
struct MilestoneGlyph: View {
    var color: Color = Theme.blue
    var size: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size * 0.72, height: size * 0.72)
            .rotationEffect(.degrees(45))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Swatch row for picking a phase color.
struct PhaseColorPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
            ForEach(ScheduleStore.phasePalette, id: \.self) { hex in
                Button {
                    selection = hex
                } label: {
                    Circle()
                        .fill(ScheduleStyle.color(hex: hex))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if selection == hex {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
                .accessibilityAddTraits(selection == hex ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
