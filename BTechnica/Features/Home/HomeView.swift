import SwiftUI

/// Project home: shortcuts into the main MVP flows and a few useful counts.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTab: AppTab

    @State private var showingPicker = false
    @State private var importError: String?
    @State private var detailsDrawingId: UUID?
    @State private var pendingEditorId: UUID?

    private var openIssueCount: Int {
        store.data.issues.filter { $0.status == .open }.count
    }

    private var issuesWithPhotos: Int {
        store.data.issues.filter { !$0.photos.isEmpty }.count
    }

    private var issuesWithoutPhotos: Int {
        store.data.issues.filter { $0.photos.isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.data.project.name)
                            .font(.title2).bold()
                        Text("Active project")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Shortcuts") {
                    Button {
                        selectedTab = .drawings
                    } label: {
                        shortcutRow(icon: "doc.richtext", title: "Open drawings")
                    }
                    Button {
                        showingPicker = true
                    } label: {
                        shortcutRow(icon: "square.and.arrow.down", title: "Import drawing")
                    }
                    Button {
                        selectedTab = .issues
                    } label: {
                        shortcutRow(icon: "exclamationmark.bubble", title: "Open issues")
                    }
                    NavigationLink {
                        ReportsView()
                    } label: {
                        shortcutRow(icon: "doc.text", title: "Issue report")
                    }
                }

                Section("Overview") {
                    summaryRow(icon: "doc.richtext",
                               title: "Drawings",
                               value: "\(store.data.drawings.count)")
                    summaryRow(icon: "exclamationmark.bubble",
                               title: "Open issues",
                               value: "\(openIssueCount)")
                    summaryRow(icon: "photo.fill",
                               title: "Issues with photos",
                               value: "\(issuesWithPhotos)")
                    summaryRow(icon: "photo",
                               title: "Issues without photos",
                               value: "\(issuesWithoutPhotos)")
                }
            }
            .navigationTitle("Home")
            .sheet(isPresented: $showingPicker, onDismiss: presentPendingEditor) {
                PDFDocumentPicker { url in
                    handlePicked(url)
                    showingPicker = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { detailsDrawingId != nil },
                set: { if !$0 { detailsDrawingId = nil } }
            ), onDismiss: {
                selectedTab = .drawings
            }) {
                if let detailsDrawingId {
                    DrawingDetailsEditor(drawingId: detailsDrawingId)
                        .environmentObject(store)
                }
            }
            .alert("Import failed",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func shortcutRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.blue)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.blue)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func handlePicked(_ url: URL) {
        do {
            let drawing = try store.importDrawing(from: url)
            pendingEditorId = drawing.id
        } catch {
            importError = error.localizedDescription
        }
    }

    private func presentPendingEditor() {
        guard let id = pendingEditorId else { return }
        pendingEditorId = nil
        DispatchQueue.main.async {
            detailsDrawingId = id
        }
    }
}

#Preview {
    HomeView(selectedTab: .constant(.home)).environmentObject(AppStore())
}
