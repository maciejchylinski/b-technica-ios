import SwiftUI

enum KnowledgeRoute: Hashable {
    case folder(UUID)
    case document(UUID, pageIndex: Int?, highlight: [String])
    case note(UUID)
}

private enum KnowledgeSection: String, CaseIterable, Identifiable {
    case library
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .notes: return "Field Notes"
        }
    }
}

/// "More → Project Documents": binds the knowledge store to the open project workspace.
struct ProjectDocumentsEntryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ProjectKnowledgeView(
            knowledge: KnowledgeStore.shared(userId: store.userId, project: store.data.project)
        )
    }
}

/// Project document library, field notes and unified offline search for one project.
struct ProjectKnowledgeView: View {
    @ObservedObject var knowledge: KnowledgeStore

    @State private var section: KnowledgeSection = .library
    @State private var query = ""
    @State private var scope: KnowledgeSearchScope = .all

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                KnowledgeSearchResultsView(knowledge: knowledge, query: query, scope: $scope)
            } else {
                switch section {
                case .library:
                    DocumentFolderView(knowledge: knowledge, folderId: nil)
                case .notes:
                    FieldNotesListView(knowledge: knowledge)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isSearching {
                Picker("Section", selection: $section) {
                    ForEach(KnowledgeSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.background)
                .accessibilityIdentifier("knowledgeSectionPicker")
            }
        }
        .background(Theme.background)
        .navigationTitle("Project Documents")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search documents and notes"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationDestination(for: KnowledgeRoute.self) { route in
            switch route {
            case .folder(let id):
                DocumentFolderView(knowledge: knowledge, folderId: id)
            case .document(let id, let pageIndex, let highlight):
                DocumentViewerView(
                    knowledge: knowledge,
                    documentId: id,
                    initialPageIndex: pageIndex,
                    highlightTerms: highlight
                )
            case .note(let id):
                NoteEditorView(knowledge: knowledge, noteId: id)
            }
        }
        .alert(
            "Project Documents",
            isPresented: Binding(
                get: { knowledge.loadError != nil },
                set: { if !$0 { knowledge.dismissLoadError() } }
            )
        ) {
            Button("OK", role: .cancel) { knowledge.dismissLoadError() }
        } message: {
            Text(knowledge.loadError ?? "")
        }
    }
}

// MARK: - Shared formatting

enum KnowledgeFormat {
    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func pages(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
    }

    /// Renders an FTS snippet, emphasising the text between match markers.
    static func snippet(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var highlighted = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer.replacingOccurrences(of: "\n", with: " "))
            if highlighted {
                part.font = Font.subheadline.weight(.semibold)
                part.foregroundColor = Color.primary
                part.backgroundColor = Color.yellow.opacity(0.35)
            }
            result += part
            buffer = ""
        }

        for character in raw {
            if character == KnowledgeSearchResult.matchStart {
                flush()
                highlighted = true
            } else if character == KnowledgeSearchResult.matchEnd {
                flush()
                highlighted = false
            } else {
                buffer.append(character)
            }
        }
        flush()
        return result
    }
}

/// Compact index-state line used in document rows and the info panel.
struct DocumentIndexBadge: View {
    let document: ProjectDocument
    let progress: DocumentIndexer.Progress?
    let fileAvailable: Bool

    var body: some View {
        if !fileAvailable {
            Label("PDF file missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if let progress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Indexing page \(min(progress.completedPages + 1, max(progress.totalPages, 1))) of \(progress.totalPages)")
            }
            .foregroundStyle(.secondary)
        } else {
            switch document.indexStatus {
            case .indexed:
                Label(indexedText, systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            case .pending, .indexing:
                Label(document.indexStatus.title, systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .failed:
                Label(DocumentIndexStatus.failed.title, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var indexedText: String {
        switch document.extractionSummary {
        case .ocr: return "Searchable · OCR"
        case .mixed: return "Searchable · text + OCR"
        case .noText?: return "No text found"
        default: return "Searchable"
        }
    }
}
