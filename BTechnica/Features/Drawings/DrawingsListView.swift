import SwiftUI

/// The Drawings tab: the heart of the app. Lists imported PDF drawings and lets
/// the user import more from the Files app.
struct DrawingsListView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingPicker = false
    @State private var importError: String?
    @State private var detailsDrawingId: UUID?
    @State private var pendingEditorId: UUID?
    @State private var pendingDelete: PendingDrawingDelete?

    var body: some View {
        NavigationStack {
            Group {
                if store.data.drawings.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Drawings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Import PDF", systemImage: "plus")
                    }
                }
            }
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
            )) {
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
            .alert("Delete drawing?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete drawing and issues", role: .destructive) {
                    confirmDeleteWithIssues()
                }
            } message: {
                Text(pendingDelete?.message ?? "")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.data.drawings) { drawing in
                NavigationLink(value: drawing.id) {
                    DrawingRow(drawing: drawing)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        requestDelete(drawing)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        detailsDrawingId = drawing.id
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Theme.blue)
                }
                .contextMenu {
                    Button {
                        detailsDrawingId = drawing.id
                    } label: {
                        Label("Edit drawing details", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        requestDelete(drawing)
                    } label: {
                        Label("Delete drawing", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: UUID.self) { drawingId in
            if store.data.drawings.contains(where: { $0.id == drawingId }) {
                DrawingDetailView(drawingId: drawingId)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No drawings yet", systemImage: "doc.richtext")
        } description: {
            Text("Import a PDF drawing from Files to get started.")
        } actions: {
            Button {
                showingPicker = true
            } label: {
                Text("Import PDF")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
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

    private func requestDelete(_ drawing: Drawing) {
        let issueCount = store.issues(for: drawing).count
        if issueCount > 0 {
            pendingDelete = PendingDrawingDelete(drawing: drawing, issueCount: issueCount)
        } else {
            _ = store.deleteDrawing(drawing)
        }
    }

    private func confirmDeleteWithIssues() {
        guard let pendingDelete else { return }
        _ = store.deleteDrawing(pendingDelete.drawing, confirmingIssueDeletion: true)
        self.pendingDelete = nil
    }
}

private struct PendingDrawingDelete {
    let drawing: Drawing
    let issueCount: Int

    var message: String {
        let noun = issueCount == 1 ? "issue" : "issues"
        return "This drawing has \(issueCount) \(noun). Deleting it also deletes those \(noun) and their photos. This cannot be undone."
    }
}

/// One row in the drawings list, showing name, optional metadata and scale status.
private struct DrawingRow: View {
    let drawing: Drawing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(drawing.name)
                    .font(.headline)
                    .lineLimit(2)

                if let revision = drawing.displayRevision {
                    Text("Rev \(revision)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let discipline = drawing.displayDiscipline {
                    Text(discipline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let location = drawing.displayLocation {
                    Text(location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(drawing.calibrationStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    DrawingsListView().environmentObject(AppStore())
}
