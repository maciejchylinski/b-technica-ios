import SwiftUI

/// Placeholder Equipment screen, reachable from More.
///
/// PRODUCT NOTE: Equipment will let site teams track tools/materials — item,
/// issued to, location, issued date, returned date and status (see
/// `EquipmentItem`). Not implemented in this first slice.
struct EquipmentView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Equipment", systemImage: "shippingbox")
        } description: {
            Text("Track site equipment and inventory: what it is, who has it, where it is, and when it was issued or returned. Coming soon.")
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        EquipmentView()
    }
}
