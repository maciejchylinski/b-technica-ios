import SwiftUI

/// Equipment register: every item the user owns, with who holds it and in which project.
/// Filters by project, status and holder; search covers name, identifiers and holder.
struct EquipmentView: View {
    @StateObject private var equipment: EquipmentStore

    @State private var searchText = ""
    @State private var scope: EquipmentProjectScope = .all
    @State private var statusFilter: EquipmentStatus?
    @State private var holderFilter: EquipmentHolder?
    @State private var showEditor = false
    @State private var pendingDelete: EquipmentItem?
    @State private var actionError: String?

    init(userId: UUID, projectId: UUID) {
        _equipment = StateObject(wrappedValue: EquipmentStore(userId: userId, projectId: projectId))
    }

    private var filtered: [EquipmentItem] {
        equipment.items
            .filter { item in
                let active = equipment.activeCheckout(for: item.id)
                if let statusFilter, item.normalizedStatus != statusFilter { return false }
                if let holderFilter, !(active.map(holderFilter.matches) ?? false) { return false }
                switch scope {
                case .all: break
                case .thisProject:
                    guard active?.projectId == equipment.projectId else { return false }
                case .project(let id):
                    guard active?.projectId == id else { return false }
                }
                return matchesSearch(item, active: active)
            }
            .sorted { $0.item.localizedCaseInsensitiveCompare($1.item) == .orderedAscending }
    }

    private var otherProjects: [(id: UUID, name: String)] {
        let ids = Set(equipment.checkouts.filter(\.isActive).compactMap(\.projectId))
            .subtracting([equipment.projectId])
        return ids.map { ($0, equipment.projectName($0) ?? "Unknown project") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hasFilters: Bool {
        scope != .all || statusFilter != nil || holderFilter != nil
    }

    var body: some View {
        Group {
            if equipment.items.isEmpty {
                ContentUnavailableView {
                    Label("No equipment yet", systemImage: "shippingbox")
                } description: {
                    Text("Add tools and equipment so you can track who has them and on which project.")
                } actions: {
                    Button("Add equipment") { showEditor = true }
                }
            } else {
                list
            }
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add equipment")
            }
        }
        .sheet(isPresented: $showEditor) {
            EquipmentEditor(equipment: equipment, itemId: nil)
        }
        .onAppear { equipment.reload() }
        .alert("Delete equipment?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let pendingDelete { actionError = equipment.delete(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes “\(pendingDelete?.item ?? "this item")” with its checkout and event history from every project. This cannot be undone.")
        }
        .alert("Equipment",
               isPresented: Binding(get: { actionError != nil || equipment.errorMessage != nil },
                                    set: { if !$0 { actionError = nil; equipment.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? equipment.errorMessage ?? "")
        }
    }

    private var list: some View {
        List {
            Section {
                EquipmentSummaryBar(equipment: equipment, statusFilter: $statusFilter)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Picker("Project", selection: $scope) {
                    Text("All equipment").tag(EquipmentProjectScope.all)
                    Text("This project").tag(EquipmentProjectScope.thisProject)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                if hasFilters {
                    Button("Clear filters") {
                        scope = .all
                        statusFilter = nil
                        holderFilter = nil
                    }
                    .font(.footnote)
                }
            }

            Section {
                ForEach(filtered) { item in
                    NavigationLink {
                        EquipmentDetailView(equipment: equipment, equipmentId: item.id)
                    } label: {
                        EquipmentRow(
                            item: item,
                            checkout: equipment.activeCheckout(for: item.id),
                            projectName: equipment.projectName(equipment.activeCheckout(for: item.id)?.projectId),
                            isCurrentProject: equipment.activeCheckout(for: item.id)?.projectId == equipment.projectId
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = item } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if item.normalizedStatus == .issued {
                            Button {
                                actionError = equipment.returnItem(id: item.id, date: Date(), condition: .good, notes: nil)
                            } label: {
                                Label("Return", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                        }
                    }
                }
            } header: {
                Text(filtered.count == 1 ? "1 item" : "\(filtered.count) items")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Name, ID, serial, holder")
        .overlay {
            if filtered.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No matching equipment", systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Project", selection: $scope) {
                Label("All equipment", systemImage: "square.stack.3d.up").tag(EquipmentProjectScope.all)
                Label("This project", systemImage: "building.columns").tag(EquipmentProjectScope.thisProject)
                ForEach(otherProjects, id: \.id) { project in
                    Text(project.name).tag(EquipmentProjectScope.project(project.id))
                }
            }
            Picker("Status", selection: $statusFilter) {
                Text("Any status").tag(EquipmentStatus?.none)
                ForEach(EquipmentStatus.current) { status in
                    Text(status.label).tag(EquipmentStatus?.some(status))
                }
            }
            Picker("Holder", selection: $holderFilter) {
                Text("Any holder").tag(EquipmentHolder?.none)
                ForEach(equipment.activeHolders) { holder in
                    Label(holder.name, systemImage: holder.systemImage).tag(EquipmentHolder?.some(holder))
                }
            }
        } label: {
            Image(systemName: hasFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter equipment")
    }

    private func matchesSearch(_ item: EquipmentItem, active: EquipmentCheckout?) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields: [String?] = [
            item.item, item.category, item.identifier, item.serialNumber, item.notes,
            active?.recipientName, active?.location
        ]
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }
}

enum EquipmentProjectScope: Hashable {
    case all
    case thisProject
    case project(UUID)
}

extension EquipmentItem {
    /// Legacy `returned` reads as `available`.
    var normalizedStatus: EquipmentStatus {
        status == .returned ? .available : status
    }
}

extension EquipmentStatus {
    var color: Color {
        switch self {
        case .available, .returned: return .green
        case .issued: return Theme.blue
        case .damaged: return .orange
        case .lost: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .available, .returned: return "checkmark.circle.fill"
        case .issued: return "person.crop.circle.badge.checkmark"
        case .damaged: return "wrench.and.screwdriver.fill"
        case .lost: return "questionmark.circle.fill"
        }
    }
}

/// Tappable status counts; tapping toggles the status filter.
private struct EquipmentSummaryBar: View {
    @ObservedObject var equipment: EquipmentStore
    @Binding var statusFilter: EquipmentStatus?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(EquipmentStatus.current) { status in
                let count = equipment.items.filter { $0.normalizedStatus == status }.count
                Button {
                    statusFilter = statusFilter == status ? nil : status
                } label: {
                    VStack(spacing: 2) {
                        Text("\(count)")
                            .font(.title3.weight(.semibold))
                        Text(status.label)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
                    .foregroundStyle(statusFilter == status ? .white : status.color)
                    .background(
                        statusFilter == status ? status.color : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) \(status.label)")
            }
        }
        .padding(.bottom, 8)
    }
}

private struct EquipmentRow: View {
    let item: EquipmentItem
    let checkout: EquipmentCheckout?
    let projectName: String?
    let isCurrentProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.normalizedStatus.systemImage)
                .font(.title3)
                .foregroundStyle(item.normalizedStatus.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.item)
                        .font(.headline)
                    if let identifier = item.displayIdentifier {
                        Text(identifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let checkout {
                    Label(checkout.recipientName, systemImage: EquipmentHolder(checkout).systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.blue)
                    Text([
                        isCurrentProject ? "This project" : (projectName ?? "No project"),
                        "since \(checkout.issuedDate.formatted(date: .abbreviated, time: .omitted))",
                        checkout.location
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text([item.normalizedStatus.label, item.displayCategory].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(item.normalizedStatus == .available ? .secondary : item.normalizedStatus.color)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
