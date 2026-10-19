import SwiftUI

/// The Drawings tab: the heart of the app. Lists imported PDF drawings and lets
/// the user import more from the Files app.
struct DrawingsListView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingPicker = false
    @State private var showSamplePicker = false
    @State private var importError: String?
    @State private var multiPageNotice: String?
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
                    Menu {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Import PDF", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showSamplePicker = true
                        } label: {
                            Label("Add sample drawing", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add drawing")
                }
            }
            .sheet(isPresented: $showingPicker, onDismiss: presentPendingEditor) {
                PDFDocumentPicker { url in
                    handlePicked(url)
                    showingPicker = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSamplePicker) {
                SampleDrawingsSheet { sample in
                    importSample(sample)
                }
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
            .alert(DrawingImportNotice.multiPageTitle,
                   isPresented: Binding(get: { multiPageNotice != nil },
                                        set: { if !$0 { multiPageNotice = nil } })) {
                Button("OK", role: .cancel) { multiPageNotice = nil }
            } message: {
                Text(multiPageNotice ?? "")
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
                .accessibilityIdentifier("drawingRow")
                .accessibilityLabel(drawing.name)
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
            Text("Import a PDF drawing from Files, or add a sample floor plan to try the app.")
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
            Button {
                showSamplePicker = true
            } label: {
                Text("Add sample drawing")
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
        }
    }

    private func handlePicked(_ url: URL) {
        Task { @MainActor in
            do {
                let drawing = try await store.importDrawing(from: url)
                noteMultiPageIfNeeded(drawing)
                pendingEditorId = drawing.id
                // Import is async; picker may already have dismissed.
                presentPendingEditor()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importSample(_ sample: SampleDrawing) {
        Task { @MainActor in
            do {
                let drawing = try await store.importSampleDrawing(sample)
                noteMultiPageIfNeeded(drawing)
                pendingEditorId = drawing.id
                presentPendingEditor()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func noteMultiPageIfNeeded(_ drawing: Drawing) {
        if drawing.isMultiPage {
            multiPageNotice = DrawingImportNotice.multiPageMessage
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
