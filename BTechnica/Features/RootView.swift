import SwiftUI

/// Primary tabs. Equipment lives under More, not in the bar.
enum AppTab: Hashable {
    case home, drawings, issues, more
}

/// Top-level tab shell, mirroring a Dalux-style field app layout.
/// The drawing/PDF is the centre of the product, so Drawings sits front of mind
/// right next to Home.
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab: AppTab = .home

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.storageError {
                storageErrorBanner(message)
            }

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
                    // Avoid `ellipsis` — XCTest resolves it as a non-hittable interruptor.
                    .tabItem { Label("More", systemImage: "line.3.horizontal") }
                    .accessibilityIdentifier("moreTab")
                    .tag(AppTab.more)
            }
            .accessibilityIdentifier("mainTabView")
        }
    }

    private func storageErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.dismissStorageError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.95))
        .accessibilityIdentifier("storageErrorBanner")
    }
}

#Preview {
    RootView()
        .environmentObject(AppStore())
        .environmentObject(AuthStore())
}
