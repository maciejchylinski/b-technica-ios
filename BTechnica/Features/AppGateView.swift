import SwiftUI

/// Routes between loading, login, and the existing authenticated app shell.
struct AppGateView: View {
    @EnvironmentObject private var auth: AuthStore
    @State private var store: AppStore?
    @State private var boundWorkspaceEpoch: Int = -1

    var body: some View {
        Group {
            switch auth.phase {
            case .loading:
                ProgressView("Starting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)

            case .signedOut:
                LoginView()

            case .signedIn:
                if let store {
                    RootView()
                        .environmentObject(store)
                } else {
                    ProgressView("Loading workspace…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                }
            }
        }
        .onChange(of: auth.phase) { _, phase in
            syncStore(for: phase)
        }
        .onChange(of: auth.session?.user.id) { _, _ in
            syncStore(for: auth.phase)
        }
        .onChange(of: auth.workspaceEpoch) { _, _ in
            syncStore(for: auth.phase)
        }
        .onAppear {
            syncStore(for: auth.phase)
        }
    }

    private func syncStore(for phase: AuthStore.Phase) {
        switch phase {
        case .signedIn:
            guard let userId = auth.userId else {
                store = nil
                boundWorkspaceEpoch = -1
                return
            }
            let adoptLegacy = auth.consumeLegacyAdoptionIntent()
            let needsNewStore =
                store == nil
                || store?.userId != userId
                || boundWorkspaceEpoch != auth.workspaceEpoch
                || adoptLegacy
            if needsNewStore {
                store = AppStore(userId: userId, adoptLegacy: adoptLegacy)
                boundWorkspaceEpoch = auth.workspaceEpoch
            }
        case .signedOut, .loading:
            store = nil
            boundWorkspaceEpoch = -1
        }
    }
}
