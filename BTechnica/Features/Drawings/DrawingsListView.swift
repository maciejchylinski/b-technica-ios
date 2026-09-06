import SwiftUI

/// The Drawings tab: the heart of the app. Lists imported PDF drawings and lets
/// the user import more from the Files app.
struct DrawingsListView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingPicker = false
    @State private var importError: String?

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
            .sheet(isPresented: $showingPicker) {
                PDFDocumentPicker { url in
                    handlePicked(url)
                }
                .ignoresSafeArea()
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

    private var list: some View {
        List {
            ForEach(store.data.drawings) { drawing in
                NavigationLink(value: drawing.id) {
                    DrawingRow(drawing: drawing)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: UUID.self) { drawingId in
            if let drawing = store.data.drawings.first(where: { $0.id == drawingId }) {
                DrawingDetailView(drawingId: drawing.id)
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
            try store.importDrawing(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let drawings = offsets.map { store.data.drawings[$0] }
        drawings.forEach { store.deleteDrawing($0) }
    }
}

/// One row in the drawings list, showing name, page count and calibration state.
private struct DrawingRow: View {
    let drawing: Drawing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(Theme.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(drawing.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(drawing.pageCount) page\(drawing.pageCount == 1 ? "" : "s")")
                    Text("·")
                    calibrationBadge
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var calibrationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: drawing.isCalibrated ? "checkmark.seal.fill" : "ruler")
            Text(drawing.calibrationStatusText)
        }
        .foregroundStyle(drawing.isCalibrated ? Color.green : Color.orange)
    }
}

#Preview {
    DrawingsListView().environmentObject(AppStore())
}
