import SwiftUI

enum GanttScale: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var dayWidth: CGFloat {
        switch self {
        case .week: return 24
        case .month: return 5
        }
    }
}

struct GanttMetrics {
    var dayWidth: CGFloat
    var rowHeight: CGFloat
    var headerHeight: CGFloat = 46
    var labelWidth: CGFloat
    /// Wide layouts show dates and progress under each task name.
    var showsLabelDetails: Bool
    var barHeight: CGFloat { rowHeight * 0.5 }

    static func make(scale: GanttScale, isRegularWidth: Bool) -> GanttMetrics {
        GanttMetrics(
            dayWidth: scale.dayWidth,
            rowHeight: isRegularWidth ? 40 : 36,
            labelWidth: isRegularWidth ? 270 : 128,
            showsLabelDetails: isRegularWidth
        )
    }

    func contentSize(for layout: GanttLayout) -> CGSize {
        CGSize(
            width: labelWidth + CGFloat(layout.dayCount) * dayWidth,
            height: headerHeight + CGFloat(layout.rows.count) * rowHeight + 48
        )
    }

    /// Content x offset that places `ordinal` at `fraction` of the timeline viewport.
    func scrollX(for ordinal: Int, in layout: GanttLayout, viewportWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        CGFloat(layout.dayIndex(ordinal)) * dayWidth - fraction * max(0, viewportWidth - labelWidth)
    }

    /// Row under a viewport point, or nil for the header / empty space.
    func row(at point: CGPoint, offset: CGPoint, in layout: GanttLayout) -> Int? {
        guard point.y >= headerHeight else { return nil }
        let index = Int(floor((point.y - headerHeight + offset.y) / rowHeight))
        return layout.rows.indices.contains(index) ? index : nil
    }
}

/// Draws only the visible slice of the chart for a given scroll offset.
/// The label column and date header are pinned; the timeline scrolls under them.
struct GanttRenderer {
    let layout: GanttLayout
    let metrics: GanttMetrics
    let scale: GanttScale
    let showsLinks: Bool

    private var origin: CalendarDay { layout.originDay }

    func draw(in ctx: inout GraphicsContext, size: CGSize, offset: CGPoint) {
        let m = metrics
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.systemBackground)))

        let firstDay = max(0, Int(floor(offset.x / m.dayWidth)) - 1)
        let lastDay = min(layout.dayCount, Int(ceil((offset.x + size.width - m.labelWidth) / m.dayWidth)) + 1)
        let firstRow = max(0, Int(floor(offset.y / m.rowHeight)))
        let lastRow = min(layout.rows.count - 1, Int(ceil((offset.y + size.height - m.headerHeight) / m.rowHeight)))

        let timelineRect = CGRect(x: m.labelWidth, y: m.headerHeight,
                                  width: max(0, size.width - m.labelWidth),
                                  height: max(0, size.height - m.headerHeight))
        var timeline = ctx
        timeline.clip(to: Path(timelineRect))
        drawTimeline(in: &timeline, size: size, offset: offset,
                     days: firstDay..<max(firstDay, lastDay), rows: firstRow...max(firstRow, lastRow))

        var header = ctx
        header.clip(to: Path(CGRect(x: m.labelWidth, y: 0, width: max(0, size.width - m.labelWidth), height: m.headerHeight)))
        drawHeader(in: &header, size: size, offset: offset, days: firstDay..<max(firstDay, lastDay))

        var labels = ctx
        labels.clip(to: Path(CGRect(x: 0, y: m.headerHeight, width: m.labelWidth, height: max(0, size.height - m.headerHeight))))
        if lastRow >= firstRow {
            drawLabels(in: &labels, offset: offset, rows: firstRow...lastRow)
        } else {
            labels.fill(Path(CGRect(x: 0, y: m.headerHeight, width: m.labelWidth, height: size.height)),
                        with: .color(Color(.systemBackground)))
        }

        drawCorner(in: &ctx, size: size)
    }

    // MARK: - Geometry

    private func x(forDay index: Int, offset: CGPoint) -> CGFloat {
        metrics.labelWidth + CGFloat(index) * metrics.dayWidth - offset.x
    }

    private func y(forRow index: Int, offset: CGPoint) -> CGFloat {
        metrics.headerHeight + CGFloat(index) * metrics.rowHeight - offset.y
    }

    // MARK: - Timeline

    private func drawTimeline(
        in ctx: inout GraphicsContext,
        size: CGSize,
        offset: CGPoint,
        days: Range<Int>,
        rows: ClosedRange<Int>
    ) {
        let m = metrics
        let top = m.headerHeight
        let height = size.height - top
        let hasRows = !layout.rows.isEmpty

        // Weekend shading and grid.
        var minor = Path()
        var major = Path()
        var weekends = Path()
        for index in days {
            let day = origin.adding(days: index)
            let x = x(forDay: index, offset: offset)
            if scale == .week, day.isWeekend {
                weekends.addRect(CGRect(x: x, y: top, width: m.dayWidth, height: height))
            }
            if day.day == 1 {
                major.move(to: CGPoint(x: x, y: top))
                major.addLine(to: CGPoint(x: x, y: size.height))
            } else if scale == .week, day.isoWeekday == 1 {
                minor.move(to: CGPoint(x: x, y: top))
                minor.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        ctx.fill(weekends, with: .color(Color.primary.opacity(0.035)))

        if hasRows {
            var separators = Path()
            for index in rows {
                let rowY = y(forRow: index, offset: offset)
                if case .phase(let phase) = layout.rows[index] {
                    ctx.fill(
                        Path(CGRect(x: m.labelWidth, y: rowY, width: size.width, height: m.rowHeight)),
                        with: .color(ScheduleStyle.color(hex: phase.colorHex).opacity(0.07))
                    )
                }
                separators.move(to: CGPoint(x: m.labelWidth, y: rowY + m.rowHeight))
                separators.addLine(to: CGPoint(x: size.width, y: rowY + m.rowHeight))
            }
            ctx.stroke(separators, with: .color(Color.primary.opacity(0.05)), lineWidth: 0.5)
        }
        ctx.stroke(minor, with: .color(Color.primary.opacity(0.07)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(Color.primary.opacity(0.18)), lineWidth: 1)

        // Today.
        let todayIndex = layout.dayIndex(layout.todayOrdinal)
        let todayX = x(forDay: todayIndex, offset: offset) + m.dayWidth / 2
        if scale == .week {
            ctx.fill(Path(CGRect(x: todayX - m.dayWidth / 2, y: top, width: m.dayWidth, height: height)),
                     with: .color(Color.red.opacity(0.06)))
        }
        var todayLine = Path()
        todayLine.move(to: CGPoint(x: todayX, y: top))
        todayLine.addLine(to: CGPoint(x: todayX, y: size.height))
        ctx.stroke(todayLine, with: .color(.red.opacity(0.8)), lineWidth: 1.5)

        guard hasRows else { return }

        if showsLinks {
            drawLinks(in: &ctx, size: size, offset: offset, rows: rows)
        }

        for index in rows {
            let rowY = y(forRow: index, offset: offset)
            switch layout.rows[index] {
            case .phase(let phase):
                drawPhaseBar(phase, rowY: rowY, in: &ctx, size: size, offset: offset)
            case .task(let row):
                drawTaskBar(row, rowY: rowY, in: &ctx, size: size, offset: offset)
            }
        }
    }

    private func drawPhaseBar(_ phase: GanttLayout.PhaseRow, rowY: CGFloat, in ctx: inout GraphicsContext, size: CGSize, offset: CGPoint) {
        guard let start = phase.startOrdinal, let finish = phase.finishOrdinal else { return }
        let m = metrics
        let x0 = x(forDay: layout.dayIndex(start), offset: offset)
        let x1 = x(forDay: layout.dayIndex(finish) + 1, offset: offset)
        guard x1 >= m.labelWidth - 4, x0 <= size.width else { return }
        let color = ScheduleStyle.color(hex: phase.colorHex)
        let midY = rowY + m.rowHeight / 2
        var bar = Path(CGRect(x: x0, y: midY - 3, width: max(2, x1 - x0), height: 6))
        bar.addRect(CGRect(x: x0, y: midY - 3, width: 3, height: 10))
        bar.addRect(CGRect(x: x1 - 3, y: midY - 3, width: 3, height: 10))
        ctx.fill(bar, with: .color(color.opacity(0.85)))

        let label = Text("\(phase.progress)%")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
        if x1 > m.labelWidth {
            ctx.draw(label, at: CGPoint(x: x1 + 6, y: midY), anchor: .leading)
        }
    }

    private func drawTaskBar(_ row: GanttLayout.TaskRow, rowY: CGFloat, in ctx: inout GraphicsContext, size: CGSize, offset: CGPoint) {
        let m = metrics
        let task = row.task
        let midY = rowY + m.rowHeight / 2
        let color = row.isBehind ? ScheduleStyle.behind : ScheduleStyle.color(hex: row.colorHex)
        let startX = x(forDay: layout.dayIndex(task.startDay.ordinal), offset: offset)
        var labelX: CGFloat

        if task.isMilestone {
            let side = min(m.rowHeight * 0.48, 16)
            let cx = startX + m.dayWidth / 2
            guard cx + side >= m.labelWidth - 200, cx - side <= size.width else { return }
            var diamond = Path()
            diamond.move(to: CGPoint(x: cx, y: midY - side / 2))
            diamond.addLine(to: CGPoint(x: cx + side / 2, y: midY))
            diamond.addLine(to: CGPoint(x: cx, y: midY + side / 2))
            diamond.addLine(to: CGPoint(x: cx - side / 2, y: midY))
            diamond.closeSubpath()
            if task.status == .completed {
                ctx.fill(diamond, with: .color(color))
            } else {
                ctx.fill(diamond, with: .color(Color(.systemBackground)))
                ctx.fill(diamond, with: .color(color.opacity(0.25)))
                ctx.stroke(diamond, with: .color(color), lineWidth: 2)
            }
            labelX = cx + side / 2 + 6
        } else {
            let width = max(3, CGFloat(task.durationDays) * m.dayWidth - 2)
            let barX = startX + 1
            guard barX + width >= m.labelWidth - 260, barX <= size.width else { return }
            let rect = CGRect(x: barX, y: midY - m.barHeight / 2, width: width, height: m.barHeight)
            let shape = Path(roundedRect: rect, cornerRadius: min(5, m.barHeight / 2))
            ctx.fill(shape, with: .color(color.opacity(0.22)))
            if task.progress > 0 {
                var progressCtx = ctx
                progressCtx.clip(to: shape)
                let filled = CGRect(x: rect.minX, y: rect.minY,
                                    width: rect.width * CGFloat(task.progress) / 100, height: rect.height)
                progressCtx.fill(Path(filled), with: .color(color.opacity(0.9)))
            }
            if row.isBehind {
                ctx.stroke(shape, with: .color(ScheduleStyle.behind), lineWidth: 1.5)
            } else if row.hasConflict {
                ctx.stroke(shape, with: .color(ScheduleStyle.conflict),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            } else {
                ctx.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: 0.75)
            }
            labelX = rect.maxX + 6
        }

        // Title beside a visible bar keeps names readable with a narrow label column.
        guard labelX > m.labelWidth, labelX < size.width else { return }
        var caption = task.title
        if !task.isMilestone { caption += " · \(task.progress)%" }
        let text = Text(caption)
            .font(.caption2)
            .foregroundColor(row.isBehind ? ScheduleStyle.behind : .secondary)
        ctx.draw(text, at: CGPoint(x: max(labelX, m.labelWidth + 4), y: midY), anchor: .leading)
    }

    private func drawLinks(in ctx: inout GraphicsContext, size: CGSize, offset: CGPoint, rows: ClosedRange<Int>) {
        let m = metrics
        let milestoneHalf = min(m.rowHeight * 0.48, 16) / 2
        var normal = Path()
        var conflict = Path()
        var normalHeads = Path()
        var conflictHeads = Path()

        for link in layout.links {
            let lo = min(link.fromRow, link.toRow)
            let hi = max(link.fromRow, link.toRow)
            guard hi >= rows.lowerBound, lo <= rows.upperBound else { continue }

            var fromX = x(forDay: layout.dayIndex(link.fromOrdinal), offset: offset)
            if link.fromIsMilestone { fromX += m.dayWidth / 2 + milestoneHalf - m.dayWidth }
            var toX = x(forDay: layout.dayIndex(link.toOrdinal), offset: offset) + 1
            if link.toIsMilestone { toX += m.dayWidth / 2 - milestoneHalf - 1 }
            guard max(fromX, toX) + 12 >= m.labelWidth, min(fromX, toX) - 12 <= size.width else { continue }

            let fromY = y(forRow: link.fromRow, offset: offset) + m.rowHeight / 2
            let toY = y(forRow: link.toRow, offset: offset) + m.rowHeight / 2
            var path = Path()
            path.move(to: CGPoint(x: fromX, y: fromY))
            let elbow: CGFloat = 6
            if toX - elbow >= fromX + elbow {
                let midX = fromX + elbow
                path.addLine(to: CGPoint(x: midX, y: fromY))
                path.addLine(to: CGPoint(x: midX, y: toY))
                path.addLine(to: CGPoint(x: toX - 1, y: toY))
            } else {
                // Successor starts too early: route around between the rows.
                let gapY = toY + (toY >= fromY ? -m.rowHeight / 2 : m.rowHeight / 2)
                path.addLine(to: CGPoint(x: fromX + elbow, y: fromY))
                path.addLine(to: CGPoint(x: fromX + elbow, y: gapY))
                path.addLine(to: CGPoint(x: toX - elbow, y: gapY))
                path.addLine(to: CGPoint(x: toX - elbow, y: toY))
                path.addLine(to: CGPoint(x: toX - 1, y: toY))
            }
            var head = Path()
            head.move(to: CGPoint(x: toX, y: toY))
            head.addLine(to: CGPoint(x: toX - 5, y: toY - 3.5))
            head.addLine(to: CGPoint(x: toX - 5, y: toY + 3.5))
            head.closeSubpath()

            if link.isConflict {
                conflict.addPath(path)
                conflictHeads.addPath(head)
            } else {
                normal.addPath(path)
                normalHeads.addPath(head)
            }
        }
        ctx.stroke(normal, with: .color(Color.secondary.opacity(0.7)), lineWidth: 1)
        ctx.fill(normalHeads, with: .color(Color.secondary.opacity(0.9)))
        ctx.stroke(conflict, with: .color(ScheduleStyle.conflict), lineWidth: 1.25)
        ctx.fill(conflictHeads, with: .color(ScheduleStyle.conflict))
    }

    // MARK: - Header

    private func drawHeader(in ctx: inout GraphicsContext, size: CGSize, offset: CGPoint, days: Range<Int>) {
        let m = metrics
        ctx.fill(Path(CGRect(x: m.labelWidth, y: 0, width: size.width, height: m.headerHeight)),
                 with: .color(Color(.secondarySystemBackground)))
        let topRowMid: CGFloat = 13
        let bottomRowMid: CGFloat = 33
        guard !days.isEmpty else { return }

        var ticks = Path()
        var majors = Path()

        // Top row: month (week scale) or year (month scale), sticky at the left edge.
        var cursor = origin.adding(days: days.lowerBound)
        cursor = scale == .week ? cursor.startOfMonth : CalendarDay(year: cursor.year, month: 1, day: 1)!
        let endDay = origin.adding(days: days.upperBound)
        while cursor <= endDay {
            let next = scale == .week ? cursor.startOfNextMonth : CalendarDay(year: cursor.year + 1, month: 1, day: 1)!
            let x0 = x(forDay: layout.dayIndex(cursor.ordinal), offset: offset)
            let x1 = x(forDay: layout.dayIndex(next.ordinal), offset: offset)
            let title = scale == .week
                ? "\(ScheduleDateFormat.monthNames[cursor.month - 1]) \(cursor.year)"
                : "\(cursor.year)"
            let resolved = ctx.resolve(Text(title).font(.caption.weight(.semibold)).foregroundColor(.primary))
            let width = resolved.measure(in: CGSize(width: 400, height: 20)).width
            let labelX = min(max(x0, m.labelWidth) + 6, x1 - width - 6)
            if labelX + width > m.labelWidth {
                ctx.draw(resolved, at: CGPoint(x: labelX, y: topRowMid), anchor: .leading)
            }
            majors.move(to: CGPoint(x: x0, y: 0))
            majors.addLine(to: CGPoint(x: x0, y: m.headerHeight))
            cursor = next
        }

        // Bottom-row labels that would sit under the Today capsule are skipped.
        let todayX = x(forDay: layout.dayIndex(layout.todayOrdinal), offset: offset) + m.dayWidth / 2
        let todayLabelGap = (todayX - 70)...(todayX + 30)

        // Bottom row: week starts (week scale) or month names (month scale).
        for index in days {
            let day = origin.adding(days: index)
            let x = x(forDay: index, offset: offset)
            switch scale {
            case .week:
                ticks.move(to: CGPoint(x: x, y: m.headerHeight - (day.isoWeekday == 1 ? 14 : 4)))
                ticks.addLine(to: CGPoint(x: x, y: m.headerHeight))
                if day.isoWeekday == 1, !todayLabelGap.contains(x) {
                    let label = Text("\(day.day) · W\(day.isoWeekOfYear)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ctx.draw(label, at: CGPoint(x: x + 4, y: bottomRowMid), anchor: .leading)
                }
            case .month:
                if day.day == 1 {
                    if !todayLabelGap.contains(x) {
                        let label = Text(ScheduleDateFormat.shortMonthNames[day.month - 1])
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ctx.draw(label, at: CGPoint(x: x + 4, y: bottomRowMid), anchor: .leading)
                    }
                    ticks.move(to: CGPoint(x: x, y: m.headerHeight - 14))
                    ticks.addLine(to: CGPoint(x: x, y: m.headerHeight))
                }
            }
        }
        ctx.stroke(ticks, with: .color(Color.primary.opacity(0.2)), lineWidth: 0.5)
        ctx.stroke(majors, with: .color(Color.primary.opacity(0.18)), lineWidth: 1)

        // Today marker.
        if todayX > m.labelWidth - 30, todayX < size.width + 30 {
            let resolved = ctx.resolve(Text("Today").font(.caption2.weight(.bold)).foregroundColor(.white))
            let textSize = resolved.measure(in: CGSize(width: 100, height: 20))
            let capsule = CGRect(x: todayX - textSize.width / 2 - 6, y: bottomRowMid - 8,
                                 width: textSize.width + 12, height: 16)
            ctx.fill(Path(roundedRect: capsule, cornerRadius: 8), with: .color(.red))
            ctx.draw(resolved, at: CGPoint(x: todayX, y: bottomRowMid), anchor: .center)
        }

        var bottom = Path()
        bottom.move(to: CGPoint(x: m.labelWidth, y: m.headerHeight - 0.5))
        bottom.addLine(to: CGPoint(x: size.width, y: m.headerHeight - 0.5))
        ctx.stroke(bottom, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
    }

    // MARK: - Label column

    private func drawLabels(in ctx: inout GraphicsContext, offset: CGPoint, rows: ClosedRange<Int>) {
        let m = metrics
        ctx.fill(Path(CGRect(x: 0, y: m.headerHeight, width: m.labelWidth, height: 10_000)),
                 with: .color(Color(.systemBackground)))
        var separators = Path()

        for index in rows {
            let rowY = y(forRow: index, offset: offset)
            let midY = rowY + m.rowHeight / 2
            switch layout.rows[index] {
            case .phase(let phase):
                let color = ScheduleStyle.color(hex: phase.colorHex)
                ctx.fill(Path(CGRect(x: 0, y: rowY, width: m.labelWidth, height: m.rowHeight)),
                         with: .color(color.opacity(0.10)))
                var chevron = ctx.resolve(
                    Image(systemName: phase.isCollapsed ? "chevron.right" : "chevron.down")
                )
                chevron.shading = .color(.secondary)
                ctx.draw(chevron, in: CGRect(x: 8, y: midY - 5, width: 10, height: 10))
                ctx.fill(Path(roundedRect: CGRect(x: 24, y: midY - 5, width: 10, height: 10), cornerRadius: 2),
                         with: .color(color))
                let count = phase.behindCount > 0 ? "\(phase.taskCount) · \(phase.behindCount)!" : "\(phase.taskCount)"
                let countText = ctx.resolve(
                    Text(count).font(.caption2.weight(.semibold))
                        .foregroundColor(phase.behindCount > 0 ? ScheduleStyle.behind : .secondary)
                )
                let countWidth = countText.measure(in: CGSize(width: 80, height: 20)).width
                ctx.draw(countText, at: CGPoint(x: m.labelWidth - 8, y: midY), anchor: .trailing)
                drawTruncated(phase.name, font: .footnote.weight(.semibold), color: .primary,
                              at: CGPoint(x: 40, y: midY), maxWidth: m.labelWidth - 56 - countWidth, in: &ctx)

            case .task(let row):
                let task = row.task
                var textX: CGFloat = 16
                if task.isMilestone {
                    var diamond = Path()
                    let cx: CGFloat = 20
                    let cy = m.showsLabelDetails ? midY - 7 : midY
                    diamond.move(to: CGPoint(x: cx, y: cy - 5))
                    diamond.addLine(to: CGPoint(x: cx + 5, y: cy))
                    diamond.addLine(to: CGPoint(x: cx, y: cy + 5))
                    diamond.addLine(to: CGPoint(x: cx - 5, y: cy))
                    diamond.closeSubpath()
                    ctx.fill(diamond, with: .color(ScheduleStyle.color(hex: row.colorHex)))
                    textX = 30
                }
                let trailingReserve: CGFloat = row.isBehind ? 22 : 8
                let titleColor: Color = row.isBehind ? ScheduleStyle.behind : .primary
                if m.showsLabelDetails {
                    drawTruncated(task.title, font: .footnote, color: titleColor,
                                  at: CGPoint(x: textX, y: midY - 7), maxWidth: m.labelWidth - textX - trailingReserve, in: &ctx)
                    let detail = task.isMilestone
                        ? ScheduleDateFormat.short(task.startDay)
                        : "\(ScheduleDateFormat.range(task)) · \(task.progress)%"
                    drawTruncated(detail, font: .caption2, color: .secondary,
                                  at: CGPoint(x: textX, y: midY + 9), maxWidth: m.labelWidth - textX - trailingReserve, in: &ctx)
                } else {
                    drawTruncated(task.title, font: .caption, color: titleColor,
                                  at: CGPoint(x: textX, y: midY), maxWidth: m.labelWidth - textX - trailingReserve, in: &ctx)
                }
                if row.isBehind {
                    var warning = ctx.resolve(Image(systemName: "exclamationmark.triangle.fill"))
                    warning.shading = .color(ScheduleStyle.behind)
                    ctx.draw(warning, in: CGRect(x: m.labelWidth - 19, y: midY - 6, width: 12, height: 12))
                }
            }
            separators.move(to: CGPoint(x: 0, y: rowY + m.rowHeight))
            separators.addLine(to: CGPoint(x: m.labelWidth, y: rowY + m.rowHeight))
        }
        ctx.stroke(separators, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)

        var edge = Path()
        edge.move(to: CGPoint(x: m.labelWidth - 0.5, y: m.headerHeight))
        edge.addLine(to: CGPoint(x: m.labelWidth - 0.5, y: 10_000))
        ctx.stroke(edge, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
    }

    private func drawCorner(in ctx: inout GraphicsContext, size: CGSize) {
        let m = metrics
        let rect = CGRect(x: 0, y: 0, width: m.labelWidth, height: m.headerHeight)
        ctx.fill(Path(rect), with: .color(Color(.secondarySystemBackground)))
        ctx.draw(Text(m.showsLabelDetails ? "Phase / task" : "Task").font(.caption.weight(.semibold)).foregroundColor(.secondary),
                 at: CGPoint(x: 12, y: m.headerHeight / 2), anchor: .leading)
        var lines = Path()
        lines.move(to: CGPoint(x: m.labelWidth - 0.5, y: 0))
        lines.addLine(to: CGPoint(x: m.labelWidth - 0.5, y: m.headerHeight))
        lines.move(to: CGPoint(x: 0, y: m.headerHeight - 0.5))
        lines.addLine(to: CGPoint(x: m.labelWidth, y: m.headerHeight - 0.5))
        ctx.stroke(lines, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
    }

    /// Single-line text with a trailing ellipsis when it does not fit.
    private func drawTruncated(_ string: String, font: Font, color: Color, at point: CGPoint,
                               maxWidth: CGFloat, in ctx: inout GraphicsContext) {
        guard maxWidth > 8 else { return }
        let bounds = CGSize(width: 10_000, height: 40)
        var resolved = ctx.resolve(Text(string).font(font).foregroundColor(color))
        var width = resolved.measure(in: bounds).width
        if width > maxWidth {
            var count = max(1, Int(Double(string.count) * Double(maxWidth / width)) - 1)
            repeat {
                resolved = ctx.resolve(Text(String(string.prefix(count)) + "…").font(font).foregroundColor(color))
                width = resolved.measure(in: bounds).width
                count -= 2
            } while width > maxWidth && count > 0
        }
        ctx.draw(resolved, at: point, anchor: .leading)
    }
}
