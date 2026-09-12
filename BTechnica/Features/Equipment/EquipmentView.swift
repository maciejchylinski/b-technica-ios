import SwiftUI

/// Local equipment list: add items, open detail, swipe delete.
struct EquipmentView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showEditor = false
    @State private var pendingDelete: EquipmentItem?

    private var sorted: [EquipmentItem] {
        store.data.equipment.sorted {
            $0.item.localizedCaseInsensitiveCompare($1.item) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if sorted.isEmpty {
                ContentUnavailableView {
                    Label("No equipment yet", systemImage: "shippingbox")
                } description: {
                    Text("Add tools and equipment so you can track who has them and where they are.")
                } actions: {
                    Button("Add equipment") {
                        showEditor = true
                    }
                }
            } else {
                List {
                    ForEach(sorted) { item in
                        NavigationLink {
                            EquipmentDetailView(equipmentId: item.id)
                        } label: {
                            EquipmentRow(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add equipment")
            }
        }
        .sheet(isPresented: $showEditor) {
            EquipmentEditor(mode: .add)
                .environmentObject(store)
        }
        .alert("Delete equipment?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    store.deleteEquipment(pendingDelete)
                }
                self.pendingDelete = nil
            }
        } message: {
            Text("This removes “\(pendingDelete?.item ?? "this item")” and its history. This cannot be undone.")
        }
    }
}

private struct EquipmentRow: View {
    let item: EquipmentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.item)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(item.status.label)
                .font(.subheadline)
                .foregroundStyle(statusColor)

            if item.status == .issued, let issuedTo = item.displayIssuedTo {
                Text(issuedTo)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let location = item.displayLocation {
                Text(location)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let category = item.displayCategory {
                Text(category)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status {
        case .available, .returned: return .green
        case .issued: return Theme.blue
        case .damaged: return .orange
        case .lost: return .red
        }
    }
}

#Preview {
    NavigationStack {
        EquipmentView()
            .environmentObject(AppStore())
    }
}
