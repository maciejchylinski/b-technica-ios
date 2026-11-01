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
            if userId == nil {
                DrawingFolderSyncCoordinator.shared.cancel()
                DrawingPDFUploadCoordinator.shared.cancel()
            }
            projects.bind(userId: userId)
            if let userId {
                LocalPersistenceBootstrap.prepareIfNeeded(userId: userId)
            }
            syncWorkspace()
        }
        .onChange(of: projects.selectedProjectId) { _, _ in
            syncWorkspace()
        }
        .onChange(of: projects.isWorkspaceOpen) { _, open in
            syncWorkspace()
            if open {
                scheduleFolderSync()
                scheduleDrawingPDFUploads()
            } else {
                DrawingFolderSyncCoordinator.shared.cancel()
                DrawingPDFUploadCoordinator.shared.cancel()
            }
        }
        .onChange(of: projects.projects) { _, _ in
            syncWorkspace()
        }
        .onChange(of: auth.phase) { _, phase in
            switch phase {
            case .signedIn:
                scheduleFolderSync()
                scheduleDrawingPDFUploads()
            case .signedOut, .loading:
                DrawingFolderSyncCoordinator.shared.cancel()
                DrawingPDFUploadCoordinator.shared.cancel()
            }
        }
        .onAppear {
            projects.bind(userId: auth.userId)
            if let userId = auth.userId {
                LocalPersistenceBootstrap.prepareIfNeeded(userId: userId)
            }
            syncWorkspace()
            scheduleFolderSync()
            scheduleDrawingPDFUploads()
        }
        .task(id: auth.userId) {
            guard auth.phase == .signedIn else { return }
            // Cloud project workspaces must not adopt legacy Documents data.
            _ = auth.consumeLegacyAdoptionIntent()
            projects.bind(userId: auth.userId)
            if let userId = auth.userId {
                LocalPersistenceBootstrap.prepareIfNeeded(userId: userId)
            }
            await projects.load(reopenWorkspace: true)
            syncWorkspace()
            scheduleFolderSync()
            scheduleDrawingPDFUploads()
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
            scheduleFolderSync()
            scheduleDrawingPDFUploads()
        } else {
            store?.applyCloudProjectName(cloud.name)
        }
    }

    private func scheduleFolderSync() {
        guard auth.phase == .signedIn,
              projects.isWorkspaceOpen,
              let userId = auth.userId,
              let projectId = projects.selectedProjectId
        else { return }
        // Single coordinator: push pending outbox, then pull (skips pending / protected folders).
        if let store {
            store.scheduleDrawingFolderSync()
        } else {
            DrawingFolderSyncCoordinator.shared.schedule(userId: userId, projectId: projectId)
        }
    }

    private func scheduleDrawingPDFUploads() {
        guard auth.phase == .signedIn,
              projects.isWorkspaceOpen,
              let userId = auth.userId,
              let projectId = projects.selectedProjectId
        else { return }
        if let store {
            store.scheduleDrawingPDFUploads()
        } else {
            DrawingPDFUploadCoordinator.shared.schedule(userId: userId, projectId: projectId)
        }
    }
}
