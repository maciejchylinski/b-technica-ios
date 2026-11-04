import SwiftUI

struct ScheduleTaskRoute: Hashable {
    let id: UUID
}

enum ScheduleSection: String, CaseIterable, Identifiable {
    case overview, tasks, upcoming, gantt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .tasks: return "Tasks"
        case .upcoming: return "Upcoming"
        case .gantt: return "Gantt"
        }
    }
}

enum ScheduleSheet: Identifiable {
    case createSchedule
    case editSchedule
    case newTask(phaseId: UUID?, kind: ScheduleTaskKind)
    case editTask(UUID)
    case newPhase
    case editPhase(UUID)
    case phases

    var id: String {
        switch self {
        case .createSchedule: return "createSchedule"
        case .editSchedule: return "editSchedule"
        case .newTask(let phaseId, let kind): return "newTask-\(phaseId?.uuidString ?? "none")-\(kind.rawValue)"
        case .editTask(let id): return "editTask-\(id)"
        case .newPhase: return "newPhase"
        case .editPhase(let id): return "editPhase-\(id)"
        case .phases: return "phases"
        }
    }
}

/// Entry point for a project's construction schedule (pushed from More / Home).
/// iPhone opens on the task list; iPad opens on the Gantt with a task inspector.
struct ScheduleHomeView: View {
    @StateObject private var store: ScheduleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSection: ScheduleSection?
    @State private var taskFilter: ScheduleTaskFilter = .all
    @State private var sheet: ScheduleSheet?
    @State private var inspectedTaskId: UUID?

    init(userId: UUID, project: Project, contractorNames: [String] = []) {
        _store = StateObject(wrappedValue: ScheduleStore(
            userId: userId,
            project: project,
            contractorNames: contractorNames
        ))
    }

    private var section: ScheduleSection {
        selectedSection ?? (horizontalSizeClass == .regular ? .gantt : .tasks)
    }

    var body: some View {
        Group {
            if store.schedule == nil {
                emptyState
            } else {
                content
                    .safeAreaInset(edge: .top, spacing: 0) { sectionPicker }
            }
        }
        .background(Theme.background)
        .navigationTitle(store.schedule?.name ?? "Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(for: ScheduleTaskRoute.self) { route in
            ScheduleTaskDetailView(taskId: route.id)
                .environmentObject(store)
        }
        .inspector(isPresented: Binding(
            get: { inspectedTaskId != nil },
            set: { if !$0 { inspectedTaskId = nil } }
        )) {
            NavigationStack {
                if let inspectedTaskId {
                    ScheduleTaskDetailView(taskId: inspectedTaskId, onClose: { self.inspectedTaskId = nil })
                        .environmentObject(store)
                        .navigationDestination(for: ScheduleTaskRoute.self) { route in
                            ScheduleTaskDetailView(taskId: route.id)
                                .environmentObject(store)
                        }
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
                .environmentObject(store)
        }
        .alert(
            "Schedule",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear { store.reload() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            ScheduleOverviewView(
                onSelectFilter: { filter in
                    taskFilter = filter
                    selectedSection = .tasks
                },
                onOpenSection: { selectedSection = $0 },
                onAddTask: { sheet = .newTask(phaseId: store.phases.first?.id, kind: .task) },
                onAddPhase: { sheet = .newPhase }
            )
        case .tasks:
            ScheduleTaskListView(
                filter: $taskFilter,
                onAddTask: { phaseId in sheet = .newTask(phaseId: phaseId, kind: .task) },
                onEditTask: { sheet = .editTask($0) },
                onAddPhase: { sheet = .newPhase },
                onEditPhase: { sheet = .editPhase($0) }
            )
        case .upcoming:
            ScheduleUpcomingView()
        case .gantt:
            if store.tasks.isEmpty && store.phases.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to chart yet", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Add phases and tasks with dates to see them on the timeline.")
                } actions: {
                    Button("Add task") { sheet = .newTask(phaseId: nil, kind: .task) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScheduleGanttView(onOpenTask: { inspectedTaskId = $0 })
            }
        }
    }

    private var sectionPicker: some View {
        Picker("View", selection: Binding(get: { section }, set: { selectedSection = $0 })) {
            ForEach(ScheduleSection.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("scheduleSectionPicker")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No schedule yet", systemImage: "calendar.badge.plus")
        } description: {
            Text("Plan phases and activities for \(store.project.name), track progress, and see everything on a Gantt chart.")
        } actions: {
            Button("Create schedule") { sheet = .createSchedule }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("createScheduleButton")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.schedule != nil {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        sheet = .newTask(phaseId: store.phases.first?.id, kind: .task)
                    } label: {
                        Label("Add task", systemImage: "plus.rectangle")
                    }
                    Button {
                        sheet = .newTask(phaseId: store.phases.first?.id, kind: .milestone)
                    } label: {
                        Label("Add milestone", systemImage: "diamond")
                    }
                    Button {
                        sheet = .newPhase
                    } label: {
                        Label("Add phase", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("scheduleAddMenu")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    sheet = .phases
                } label: {
                    Label("Manage phases", systemImage: "list.bullet.indent")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    sheet = .editSchedule
                } label: {
                    Label("Schedule settings", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ScheduleSheet) -> some View {
        switch sheet {
        case .createSchedule:
            ScheduleFormSheet(mode: .create(defaultName: "\(store.project.name) schedule"))
        case .editSchedule:
            ScheduleFormSheet(mode: .edit)
        case .newTask(let phaseId, let kind):
            if let draft = store.newTaskDraft(phaseId: phaseId, kind: kind) {
                ScheduleTaskEditor(draft: draft, isNew: true)
            }
        case .editTask(let id):
            if let task = store.task(id: id) {
                ScheduleTaskEditor(draft: task, isNew: false)
            }
        case .newPhase:
            if let draft = store.newPhaseDraft() {
                SchedulePhaseEditor(draft: draft, isNew: true)
            }
        case .editPhase(let id):
            if let phase = store.phase(id: id) {
                SchedulePhaseEditor(draft: phase, isNew: false)
            }
        case .phases:
            SchedulePhasesView()
        }
    }
}
