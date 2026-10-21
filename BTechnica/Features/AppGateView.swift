import SwiftUI

/// Routes loading → login → projects list → local project workspace.
/// Cloud projects come from Supabase; each workspace is local-only on device.
struct AppGateView: View {
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var projects = ProjectsStore()
    @State private var store: AppStore?
    @State private var boundProjectId: UUID?

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
                signedInContent
            }
        }
        .onChange(of: auth.userId) { _, userId in
            projects.bind(userId: userId)
            syncWorkspace()
        }
        .onChange(of: projects.selectedProjectId) { _, _ in
            syncWorkspace()
        }
        .onChange(of: projects.isWorkspaceOpen) { _, _ in
            syncWorkspace()
        }
        .onChange(of: projects.projects) { _, _ in
            syncWorkspace()
        }
        .onAppear {
            projects.bind(userId: auth.userId)
            syncWorkspace()
        }
        .task(id: auth.userId) {
            guard auth.phase == .signedIn else { return }
            // Cloud project workspaces must not adopt legacy Documents data.
            _ = auth.consumeLegacyAdoptionIntent()
            projects.bind(userId: auth.userId)
            await projects.load(reopenWorkspace: true)
            syncWorkspace()
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        if projects.isWorkspaceOpen {
            if let store {
                RootView()
                    .environmentObject(store)
                    .environmentObject(projects)
            } else if projects.selectedProjectId != nil {
                ProgressView("Opening project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else {
                ProjectsView()
                    .environmentObject(projects)
            }
        } else {
            ProjectsView()
                .environmentObject(projects)
        }
    }

    private func syncWorkspace() {
        guard auth.phase == .signedIn,
              projects.isWorkspaceOpen,
              let userId = auth.userId,
              let projectId = projects.selectedProjectId,
              let cloud = projects.projects.first(where: { $0.id == projectId })
        else {
            store = nil
            boundProjectId = nil
            return
        }

        if store == nil || store?.userId != userId || boundProjectId != projectId {
            store = AppStore(
                userId: userId,
                projectId: projectId,
                projectName: cloud.name,
                createdDate: cloud.createdAt
            )
            boundProjectId = projectId
        } else {
            store?.applyCloudProjectName(cloud.name)
        }
    }
}
