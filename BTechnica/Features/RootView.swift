import SwiftUI

/// Top-level tab shell, mirroring a Dalux-style field app layout.
/// The drawing/PDF is the centre of the product, so Drawings sits front of mind
/// right next to Home.
struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }

            DrawingsListView()
                .tabItem { Label("Drawings", systemImage: "doc.richtext") }

            IssuesView()
                .tabItem { Label("Issues", systemImage: "exclamationmark.bubble") }

            EquipmentView()
                .tabItem { Label("Equipment", systemImage: "shippingbox") }

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis") }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppStore())
}
