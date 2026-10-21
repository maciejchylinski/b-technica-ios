import SwiftUI

/// Lists cloud projects for the signed-in user and supports creating a new one.
/// Selecting a project opens that project's local (on-device) workspace.
struct ProjectsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var projects: ProjectsStore

    @State private var showingCreate = false
    @State private var newProjectName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if projects.isLoading && projects.projects.isEmpty {
                    ProgressView("Loading projects…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if projects.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .background(Theme.background)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await auth.signOut() }
                    } label: {
                        if auth.isBusy {
                            ProgressView()
                        } else {
                            Text("Sign Out")
                        }
                    }
                    .disabled(auth.isBusy)
                    .accessibilityIdentifier("signOutButton")
                    .accessibilityLabel("Sign Out")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newProjectName = ""
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("createProjectButton")
                    .accessibilityLabel("Create Project")
                }
            }
            .refreshable {
                await projects.load()
            }
            .sheet(isPresented: $showingCreate) {
                createSheet
            }
            .safeAreaInset(edge: .top) {
                if let message = projects.errorMessage {
                    errorBanner(message)
                }
            }
        }
        .accessibilityIdentifier("projectsScreen")
        .task(id: auth.userId) {
            projects.bind(userId: auth.userId)
            await projects.load()
        }
    }

    private var projectList: some View {
        List {
            if let email = auth.userEmail {
                Section {
                    LabeledContent("Signed in", value: email)
                }
            }

            Section {
                ForEach(projects.projects) { project in
                    Button {
                        Task { await projects.select(project) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(project.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if projects.selectedProjectId == project.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.blue)
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .frame(minHeight: Theme.touchTarget - 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projectRow-\(project.id.uuidString)")
                    .accessibilityLabel(project.name)
                }
            } footer: {
                Text("Each project keeps its own local drawings, issues, and photos on this device. Cloud sync is not enabled yet.")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder")
        } description: {
            Text("Create a project to get started. Your projects stay private to your account.")
        } actions: {
            Button("Create Project") {
                newProjectName = ""
                showingCreate = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("createProjectEmptyButton")
        }
        .accessibilityIdentifier("projectsEmptyState")
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $newProjectName)
                        .textInputAutocapitalization(.words)
                        .disabled(projects.isSaving)
                        .focused($nameFieldFocused)
                        .accessibilityIdentifier("projectNameField")
                } footer: {
                    Text("Name is required.")
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingCreate = false
                    }
                    .disabled(projects.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            let ok = await projects.create(name: newProjectName)
                            if ok {
                                showingCreate = false
                            }
                        }
                    }
                    .disabled(
                        projects.isSaving
                            || newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("createProjectConfirmButton")
                }
            }
            .onAppear {
                nameFieldFocused = true
            }
            .interactiveDismissDisabled(projects.isSaving)
        }
        .presentationDetents([.medium])
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                projects.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.95))
        .accessibilityIdentifier("projectsErrorBanner")
    }
}

#Preview {
    ProjectsView()
        .environmentObject(AuthStore())
        .environmentObject(ProjectsStore())
}
