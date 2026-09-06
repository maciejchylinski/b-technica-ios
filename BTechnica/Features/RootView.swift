import SwiftUI

/// Primary tabs. Equipment lives under More, not in the bar.
enum AppTab: Hashable {
    case home, drawings, issues, more
}

/// Top-level tab shell, mirroring a Dalux-style field app layout.
/// The drawing/PDF is the centre of the product, so Drawings sits front of mind
/// right next to Home.
struct RootView: View {
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            DrawingsListView()
                .tabItem { Label("Drawings", systemImage: "doc.richtext") }
                .tag(AppTab.drawings)

            IssuesView()
                .tabItem { Label("Issues", systemImage: "exclamationmark.bubble") }
                .tag(AppTab.issues)

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(AppTab.more)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppStore())
}
