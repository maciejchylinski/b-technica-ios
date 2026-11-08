import SwiftUI

/// "More" tab: project info, account, dictionaries, and secondary tools.
struct MoreView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var projects: ProjectsStore

    var body: some View {
        NavigationStack {
            List {
                Section("Project") {
                    LabeledContent("Name", value: store.data.project.name)
                    LabeledContent(
                        "Created",
                        value: store.data.project.createdDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    LabeledContent("Data", value: "Local on this device")
                    Text("Drawings, issues, and photos for this project stay on-device. They are not synced to Supabase yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Switch Project") {
                        #if DEBUG
                        if DemoMode.isDemoUser(store.userId) {
                            DemoModeController.shared.closeProject()
                            return
                        }
                        #endif
                        projects.leaveWorkspace()
                    }
                    .accessibilityIdentifier("switchProjectButton")
                }

                Section("Planning") {
                    NavigationLink {
                        ScheduleHomeView(
                            userId: store.userId,
                            project: store.data.project,
                            contractorNames: store.data.contractors.map(\.name)
                        )
                    } label: {
                        Label("Schedule & Gantt", systemImage: "chart.bar.xaxis")
                    }
                    .accessibilityIdentifier("scheduleLink")
                }

                #if DEBUG
                if DemoMode.isDemoUser(store.userId) {
                    Section {
                        Button("Exit demo mode") {
                            DemoModeController.shared.exit()
                        }
                        .accessibilityIdentifier("exitDemoFromMoreButton")
                    } header: {
                        Text("Demo mode")
                    } footer: {
                        Text("Fictional local data. Nothing is synced to Supabase. Reset is available on the demo project list.")
                    }
                } else {
                    accountSection
                }
                #else
                accountSection
                #endif

                Section {
                    NavigationLink {
                        ProjectContactsView(userId: store.userId, projectId: store.projectId)
                    } label: {
                        Label("Contacts", systemImage: "person.crop.rectangle.stack")
                    }
                    .accessibilityIdentifier("projectContactsLink")
                    NavigationLink {
                        PhotoGalleryView(userId: store.userId, projectId: store.projectId)
                    } label: {
                        Label("Photo documentation", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("photoDocumentationLink")
                    NavigationLink {
                        EquipmentView(userId: store.userId, projectId: store.projectId)
                    } label: {
                        Label("Equipment", systemImage: "shippingbox")
                    }
                    .accessibilityIdentifier("equipmentLink")
                } header: {
                    Text("Field operations")
                } footer: {
                    Text("Local only on this device until synchronization is added. Contacts and equipment are shared across your projects; photos belong to this project.")
                }

                Section("Tools") {
                    NavigationLink {
                        ProjectDocumentsEntryView()
                    } label: {
                        Label("Project Documents", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("projectDocumentsLink")
                    NavigationLink {
                        ReportsView()
                    } label: {
                        Label("Reports", systemImage: "doc.text")
                    }
                    NavigationLink {
                        ContractorsView()
                    } label: {
                        Label("Contractors", systemImage: "person.2")
                    }
                    NavigationLink {
                        DisciplinesView()
                    } label: {
                        Label("Disciplines", systemImage: "tag")
                    }
                }

                Section {
                    Text("Contractors and disciplines are shared across your projects on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("App") {
                    LabeledContent("Name", value: "BTechnica")
                    LabeledContent("Mode", value: "Offline · local storage")
                }

                Section {
                    Text("BTechnica is an offline-first construction field app. Import a PDF drawing, pin issues, and attach photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("More")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            if let email = auth.userEmail {
                LabeledContent("Signed in", value: email)
            }
            Button(role: .destructive) {
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
    }
}

#Preview {
    MoreView()
        .environmentObject(AppStore())
        .environmentObject(AuthStore())
        .environmentObject(ProjectsStore())
}
