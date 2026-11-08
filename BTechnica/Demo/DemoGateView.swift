// Debug-only demo workspace (fictional data, no Supabase).
#if DEBUG
import SwiftUI

/// DEBUG-only entry to the local demo workspace: no Supabase sign-in, no sync.
/// Opening a project shows the regular workspace (`RootView`) bound to the demo user.
struct DemoGateView: View {
    @ObservedObject var controller: DemoModeController
    /// MoreView requires a ProjectsStore; the demo never loads cloud projects with it.
    @StateObject private var placeholderProjects = ProjectsStore()
    @State private var confirmReset = false

    var body: some View {
        Group {
            if let store = controller.store {
                RootView()
                    .environmentObject(store)
                    .environmentObject(placeholderProjects)
                    .id(store.projectId)
            } else {
                projectPicker
            }
        }
        .task {
            if controller.phase == .idle {
                await controller.prepare()
            }
        }
    }

    private var projectPicker: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Demo mode (DEBUG)")
                                .font(.headline)
                            Text("Fictional data stored only on this device in a separate demo workspace. "
                                 + "Nothing is sent to Supabase.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "theatermasks.fill")
                            .foregroundStyle(Theme.blue)
                    }
                }

                switch controller.phase {
                case .idle, .preparing:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Preparing demo data…")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                        Button("Try again") {
                            Task { await controller.prepare() }
                        }
                    }
                case .ready:
                    Section {
                        ForEach(controller.projects) { project in
                            Button {
                                controller.open(project)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(project.description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Text("\(project.drawingCount) drawings · \(project.issueCount) issues")
                                        .font(.caption)
                                        .foregroundStyle(Theme.blue)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("demoProjectRow-\(project.id.uuidString)")
                        }
                    } header: {
                        Text("Demo projects")
                    } footer: {
                        if let report = controller.lastReport {
                            Text(report.seeded ? "Demo data created (\(report.seedVersion))."
                                                 : "Demo data up to date (\(report.seedVersion)).")
                        }
                    }
                }

                Section {
                    Button("Reset demo data", role: .destructive) {
                        confirmReset = true
                    }
                    .disabled(controller.phase == .preparing)
                    .accessibilityIdentifier("resetDemoDataButton")
                    Button("Exit demo mode") {
                        controller.exit()
                    }
                    .accessibilityIdentifier("exitDemoButton")
                } footer: {
                    Text("Reset deletes and recreates only the demo workspace. Your own projects and accounts are not touched.")
                }
            }
            .navigationTitle("B Technica Demo")
            .confirmationDialog(
                "Reset demo data?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset demo data", role: .destructive) {
                    Task { await controller.resetDemoData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All changes made in the demo projects are discarded and the original demo data is recreated.")
            }
        }
        .accessibilityIdentifier("demoGateScreen")
    }
}
#endif
