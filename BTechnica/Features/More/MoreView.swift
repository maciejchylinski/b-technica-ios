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
                        projects.leaveWorkspace()
                    }
                    .accessibilityIdentifier("switchProjectButton")
                }

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

                Section("Tools") {
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
                    NavigationLink {
                        EquipmentView()
                    } label: {
                        Label("Equipment", systemImage: "shippingbox")
                    }
                }

                Section {
                    Text("Contractors and equipment are shared across your projects on this device.")
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
}

#Preview {
    MoreView()
        .environmentObject(AppStore())
        .environmentObject(AuthStore())
        .environmentObject(ProjectsStore())
}
