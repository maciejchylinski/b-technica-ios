import SwiftUI

/// Unified offline search over indexed document pages, document details and field notes
/// of the active project.
struct KnowledgeSearchResultsView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let query: String
    @Binding var scope: KnowledgeSearchScope

    @State private var results: [KnowledgeSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var completedKey: SearchKey?

    private struct SearchKey: Equatable {
        var query: String
        var scope: KnowledgeSearchScope
        /// Changes when indexed content changes, so visible results refresh.
        var contentVersion: Int
    }

    private var key: SearchKey {
        var hasher = Hasher()
        for document in knowledge.documents {
            hasher.combine(document.id)
            hasher.combine(document.indexStatus)
            hasher.combine(document.updatedAt)
        }
        for note in knowledge.notes {
            hasher.combine(note.id)
            hasher.combine(note.updatedAt)
        }
        return SearchKey(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scope,
            contentVersion: hasher.finalize()
        )
    }

    private var availableScopes: [KnowledgeSearchScope] {
        let used = Set(knowledge.documents.map(\.category))
        let categories = DocumentCategory.allCases.filter { used.contains($0) }.map(KnowledgeSearchScope.category)
        return [.all, .documents, .notes] + categories
    }

    private var unindexedCount: Int {
        knowledge.documents.filter { $0.indexStatus != .indexed }.count
    }

    var body: some View {
        List {
            Section {
                scopePicker
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else if KnowledgeQueryParser.matchExpression(for: query) == nil {
                Section {
                    Text("Type a word or phrase. Use quotes for an exact phrase, e.g. \u{201C}beton C25/30\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if results.isEmpty && !isSearching && completedKey == key {
                Section {
                    ContentUnavailableView.search(text: query)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { result in
                        NavigationLink(value: route(for: result)) {
                            KnowledgeSearchResultRow(result: result)
                        }
                        .accessibilityIdentifier("knowledgeSearchResult")
                    }
                } header: {
                    if isSearching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Searching…")
                        }
                    } else if !results.isEmpty {
                        Text(results.count == 1 ? "1 result" : "\(results.count) results")
                    }
                }
            }

            if unindexedCount > 0 && scope != .notes {
                Section {
                    Label(
                        unindexedCount == 1
                            ? "1 document is not indexed yet, so its text is not searchable."
                            : "\(unindexedCount) documents are not indexed yet, so their text is not searchable.",
                        systemImage: "clock"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .task(id: key) {
            await runSearch(for: key)
        }
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableScopes, id: \.self) { option in
                    Button {
                        scope = option
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(scope == option ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(scope == option ? Theme.blue : Theme.surface)
                            )
                            .foregroundStyle(scope == option ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(scope == option ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func route(for result: KnowledgeSearchResult) -> KnowledgeRoute {
        switch result.reference.sourceType {
        case .note:
            return .note(result.reference.sourceId)
        case .document, .documentPage:
            return .document(
                result.reference.sourceId,
                pageIndex: result.reference.pageIndex,
                highlight: KnowledgeQueryParser.parse(query).highlightTerms
            )
        }
    }

    private func runSearch(for key: SearchKey) async {
        guard KnowledgeQueryParser.matchExpression(for: key.query) != nil else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        // Debounce typing.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        isSearching = true
        let outcome = await knowledge.search(key.query, scope: key.scope)
        guard !Task.isCancelled else { return }
        isSearching = false
        switch outcome {
        case .success(let found):
            results = found
            errorMessage = nil
        case .failure(let error):
            results = []
            errorMessage = error.message
        }
        completedKey = key
    }
}

private struct KnowledgeSearchResultRow: View {
    let result: KnowledgeSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(Theme.blue)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.reference.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.snippet.isEmpty {
                    Text(KnowledgeFormat.snippet(result.snippet))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch result.reference.sourceType {
        case .note: return "note.text"
        case .document, .documentPage: return result.documentCategory?.systemImage ?? "doc"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch result.reference.sourceType {
        case .documentPage:
            if let page = result.reference.pageNumber { parts.append("Page \(page)") }
        case .document:
            parts.append("Document details")
        case .note:
            parts.append("Field note")
        }
        if let revision = result.reference.revision { parts.append("Rev \(revision)") }
        if let category = result.documentCategory { parts.append(category.title) }
        if let category = result.noteCategory { parts.append(category.title) }
        return parts.joined(separator: " · ")
    }
}
