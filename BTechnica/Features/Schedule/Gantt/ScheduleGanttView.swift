import SwiftUI

/// Interactive Gantt: pinned task column and date header, horizontally and
/// vertically scrolling timeline, week / month scales, today line, milestones,
/// progress fill, finish-to-start arrows, and behind-schedule highlighting.
struct ScheduleGanttView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let onOpenTask: (UUID) -> Void

    @AppStorage("schedule.gantt.scale") private var scaleRaw = GanttScale.week.rawValue
    @AppStorage("schedule.gantt.showLinks") private var showsLinks = true
    @State private var collapsed: Set<GanttLayout.GroupKey> = []
    /// Not observed here: only `GanttCanvasView` redraws on scroll.
    @State private var scroll = GanttScrollController()
    @State private var didInitialScroll = false

    private var scale: GanttScale { GanttScale(rawValue: scaleRaw) ?? .week }
    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        let today = CalendarDay.today()
        let layout = GanttLayout(snapshot: store.snapshot, collapsed: collapsed, today: today)
        let metrics = GanttMetrics.make(scale: scale, isRegularWidth: isRegular)

        VStack(spacing: 0) {
            controls(layout: layout, metrics: metrics)
            Divider()
            ZStack {
                GanttCanvasView(
                    scroll: scroll,
                    renderer: GanttRenderer(layout: layout, metrics: metrics, scale: scale, showsLinks: showsLinks)
                )
                GanttScrollView(
                    contentSize: metrics.contentSize(for: layout),
                    controller: scroll
                ) { point in
                    handleTap(at: point, layout: layout, metrics: metrics)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gantt chart with \(store.tasks.count) activities")
            .accessibilityHint("Use the Tasks view to browse activities with VoiceOver.")
            Divider()
            legend(layout: layout)
        }
        .onAppear {
            guard !didInitialScroll else { return }
            didInitialScroll = true
            DispatchQueue.main.async {
                scrollToToday(layout: layout, metrics: metrics, animated: false)
            }
        }
        .onChange(of: scaleRaw) { oldValue, newValue in
            rescale(from: GanttScale(rawValue: oldValue) ?? .week, to: GanttScale(rawValue: newValue) ?? .week, layout: layout)
        }
    }

    // MARK: - Controls

    private func controls(layout: GanttLayout, metrics: GanttMetrics) -> some View {
        HStack(spacing: 8) {
            Picker("Scale", selection: $scaleRaw) {
                ForEach(GanttScale.allCases) { value in
                    Text(value.label).tag(value.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
            .accessibilityIdentifier("ganttScalePicker")

            Spacer(minLength: 4)

            Button {
                scroll.scroll(byX: -pageWidth(metrics))
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Earlier")

            Button("Today") {
                scrollToToday(layout: layout, metrics: metrics, animated: true)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("ganttTodayButton")

            Button {
                scroll.scroll(byX: pageWidth(metrics))
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Later")

            Menu {
                Toggle("Show dependencies", isOn: $showsLinks)
                Divider()
                Button("Expand all phases") { collapsed.removeAll() }
                Button("Collapse all phases") {
                    collapsed = Set(store.phases.map { Optional($0.id) }).union(store.hasUnphasedTasks ? [nil] : [])
                }
                Divider()
                if let first = layout.firstTaskStartOrdinal {
                    Button("Go to schedule start") {
                        scroll.scroll(toX: metrics.scrollX(for: first, in: layout, viewportWidth: scroll.viewportSize.width, fraction: 0.05), animated: true)
                    }
                }
                if let last = layout.lastTaskFinishOrdinal {
                    Button("Go to schedule finish") {
                        scroll.scroll(toX: metrics.scrollX(for: last, in: layout, viewportWidth: scroll.viewportSize.width, fraction: 0.8), animated: true)
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Chart options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func legend(layout: GanttLayout) -> some View {
        HStack(spacing: 14) {
            legendItem("Progress") {
                RoundedRectangle(cornerRadius: 3).fill(Theme.blue).frame(width: 18, height: 8)
            }
            legendItem("Milestone") {
                MilestoneGlyph(size: 11)
            }
            legendItem(layout.behindCount > 0 ? "Behind (\(layout.behindCount))" : "Behind") {
                RoundedRectangle(cornerRadius: 3).stroke(ScheduleStyle.behind, lineWidth: 1.5).frame(width: 18, height: 8)
            }
            if isRegular {
                legendItem("Date conflict") {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(ScheduleStyle.conflict, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 18, height: 8)
                }
                legendItem("Today") {
                    Rectangle().fill(.red).frame(width: 2, height: 12)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }

    private func legendItem(_ label: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 5) {
            swatch()
            Text(label).lineLimit(1)
        }
    }

    // MARK: - Actions

    private func pageWidth(_ metrics: GanttMetrics) -> CGFloat {
        max(120, (scroll.viewportSize.width - metrics.labelWidth) * 0.8)
    }

    private func scrollToToday(layout: GanttLayout, metrics: GanttMetrics, animated: Bool) {
        let width = scroll.viewportSize.width > 0 ? scroll.viewportSize.width : 390
        scroll.scroll(toX: metrics.scrollX(for: layout.todayOrdinal, in: layout, viewportWidth: width, fraction: 0.25),
                      animated: animated)
    }

    /// Keeps the day in the middle of the viewport in place when switching scale.
    private func rescale(from old: GanttScale, to new: GanttScale, layout: GanttLayout) {
        let oldMetrics = GanttMetrics.make(scale: old, isRegularWidth: isRegular)
        let newMetrics = GanttMetrics.make(scale: new, isRegularWidth: isRegular)
        let timelineWidth = max(0, scroll.viewportSize.width - oldMetrics.labelWidth)
        let centerIndex = Int((scroll.offset.x + timelineWidth / 2) / oldMetrics.dayWidth)
        let centerOrdinal = layout.originDay.ordinal + centerIndex
        let width = scroll.viewportSize.width
        DispatchQueue.main.async {
            scroll.scroll(toX: newMetrics.scrollX(for: centerOrdinal, in: layout, viewportWidth: width, fraction: 0.5),
                          animated: false)
        }
    }

    private func handleTap(at point: CGPoint, layout: GanttLayout, metrics: GanttMetrics) {
        guard let index = metrics.row(at: point, offset: scroll.offset, in: layout) else { return }
        switch layout.rows[index] {
        case .phase(let phase):
            if collapsed.contains(phase.key) {
                collapsed.remove(phase.key)
            } else {
                collapsed.insert(phase.key)
            }
        case .task(let row):
            onOpenTask(row.task.id)
        }
    }
}

/// The only view that observes scrolling; redraws the visible slice each frame.
private struct GanttCanvasView: View {
    @ObservedObject var scroll: GanttScrollController
    let renderer: GanttRenderer

    var body: some View {
        let offset = scroll.offset
        Canvas { ctx, size in
            renderer.draw(in: &ctx, size: size, offset: offset)
        }
    }
}
