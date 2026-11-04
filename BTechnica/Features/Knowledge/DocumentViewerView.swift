import PDFKit
import SwiftUI

struct PageNavigationRequest: Equatable {
    let id = UUID()
    let pageIndex: Int
}

/// Read-only PDF reader for a library document: page navigation, go-to-page,
/// and highlighting of search terms on the page opened from a search result.
struct DocumentViewerView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let documentId: UUID
    let initialPageIndex: Int?
    let highlightTerms: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var currentPageIndex = 0
    @State private var pageCount = 0
    @State private var navigationRequest: PageNavigationRequest?
    @State private var loadError: String?
    @State private var highlightNotice: String?
    @State private var showInfo = false
    @State private var showGoToPage = false
    @State private var goToPageText = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let document = knowledge.document(id: documentId) {
                if !knowledge.isFileAvailable(document) {
                    missingFileState(document)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Cannot open PDF", systemImage: "doc.questionmark")
                    } description: {
                        Text(loadError)
                    }
                } else {
                    reader(document)
                }
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc")
            }
        }
        .navigationTitle(knowledge.document(id: documentId)?.name ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let document = knowledge.document(id: documentId) {
                if knowledge.isFileAvailable(document) {
                    ToolbarItem(placement: .secondaryAction) {
                        ShareLink(item: knowledge.fileURL(for: document)) {
                            Label("Share PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInfo.toggle()
                    } label: {
                        Label("Document info", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("knowledgeDocumentInfoButton")
                }
            }
        }
        .inspector(isPresented: $showInfo) {
            NavigationStack {
                DocumentInfoView(knowledge: knowledge, documentId: documentId, showsDoneButton: true) {
                    showInfo = false
                    dismiss()
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .alert("Go to Page", isPresented: $showGoToPage) {
            TextField("Page number", text: $goToPageText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Go") { goToTypedPage() }
        } message: {
            Text("Enter a page between 1 and \(max(pageCount, 1)).")
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete document", role: .destructive) {
                _ = knowledge.deleteDocument(id: documentId)
                dismiss()
            }
        } message: {
            Text("The PDF file is missing on this device. Deleting removes its record and search index.")
        }
    }

    private func reader(_ document: ProjectDocument) -> some View {
        DocumentPDFView(
            url: knowledge.fileURL(for: document),
            initialPageIndex: initialPageIndex,
            highlightTerms: highlightTerms,
            navigationRequest: navigationRequest,
            onPageChange: { index, count in
                currentPageIndex = index
                pageCount = count
            },
            onLoad: { result in
                switch result {
                case .loaded(let count, let highlights):
                    pageCount = count
                    if initialPageIndex != nil, !highlightTerms.isEmpty, highlights == 0 {
                        highlightNotice = "Match found in the page text, but it cannot be highlighted here (scanned page or different wording)."
                    }
                case .failed(let message):
                    loadError = message
                }
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            if let highlightNotice {
                Text(highlightNotice)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                    .onTapGesture { self.highlightNotice = nil }
                    .task {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        self.highlightNotice = nil
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pageBar
        }
    }

    private var pageBar: some View {
        HStack(spacing: 12) {
            Button {
                navigate(to: currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .disabled(currentPageIndex <= 0)
            .accessibilityLabel("Previous page")

            Spacer()

            Button {
                goToPageText = ""
                showGoToPage = true
            } label: {
                Text(pageCount > 0 ? "Page \(currentPageIndex + 1) of \(pageCount)" : "Loading…")
                    .font(.subheadline.monospacedDigit())
                    .frame(minHeight: Theme.touchTarget)
            }
            .disabled(pageCount <= 1)
            .accessibilityIdentifier("knowledgePageIndicator")

            Spacer()

            Button {
                navigate(to: currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .disabled(currentPageIndex >= pageCount - 1)
            .accessibilityLabel("Next page")
        }
        .padding(.horizontal, 12)
        .background(.bar)
    }

    private func missingFileState(_ document: ProjectDocument) -> some View {
        ContentUnavailableView {
            Label("PDF file missing", systemImage: "exclamationmark.triangle")
        } description: {
            Text("\u{201C}\(document.originalFileName)\u{201D} is no longer stored on this device. Its details and any extracted text are kept. Delete the record and import the PDF again to restore it.")
        } actions: {
            Button("Delete record", role: .destructive) { confirmDelete = true }
                .buttonStyle(.bordered)
        }
    }

    private func navigate(to index: Int) {
        guard pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        navigationRequest = PageNavigationRequest(pageIndex: clamped)
    }

    private func goToTypedPage() {
        guard let number = Int(goToPageText.trimmingCharacters(in: .whitespaces)) else { return }
        navigate(to: number - 1)
    }
}

/// `PDFView` wrapper used by the document library. Loads off the main thread.
struct DocumentPDFView: UIViewRepresentable {
    enum LoadResult {
        case loaded(pageCount: Int, highlightCount: Int)
        case failed(String)
    }

    let url: URL
    let initialPageIndex: Int?
    let highlightTerms: [String]
    let navigationRequest: PageNavigationRequest?
    var onPageChange: (Int, Int) -> Void
    var onLoad: (LoadResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemGroupedBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        pdfView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])
        context.coordinator.spinner = spinner
        context.coordinator.observePageChanges(of: pdfView)
        context.coordinator.load(into: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        if let request = navigationRequest, request != context.coordinator.lastNavigation {
            context.coordinator.lastNavigation = request
            if let page = pdfView.document?.page(at: request.pageIndex) {
                pdfView.go(to: page)
            }
        }
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: DocumentPDFView
        var spinner: UIActivityIndicatorView?
        var lastNavigation: PageNavigationRequest?

        init(_ parent: DocumentPDFView) {
            self.parent = parent
        }

        func observePageChanges(of pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            parent.onPageChange(document.index(for: page), document.pageCount)
        }

        func load(into pdfView: PDFView) {
            spinner?.startAnimating()
            let url = parent.url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let document = PDFDocument(url: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner?.stopAnimating()
                    guard let document else {
                        self.parent.onLoad(.failed("This file could not be opened as a PDF. It may be damaged."))
                        return
                    }
                    if document.isLocked && !document.unlock(withPassword: "") {
                        self.parent.onLoad(.failed("This PDF is password-protected and cannot be previewed."))
                        return
                    }
                    pdfView.document = document
                    let highlights = self.showInitialPage(in: pdfView, document: document)
                    self.parent.onLoad(.loaded(pageCount: document.pageCount, highlightCount: highlights))
                    if let page = pdfView.currentPage {
                        self.parent.onPageChange(document.index(for: page), document.pageCount)
                    }
                }
            }
        }

        /// Opens the requested page and highlights search terms on it. Returns the highlight count.
        private func showInitialPage(in pdfView: PDFView, document: PDFDocument) -> Int {
            guard let index = parent.initialPageIndex,
                  index >= 0, index < document.pageCount,
                  let page = document.page(at: index) else { return 0 }

            let selections = Self.selections(on: page, terms: parent.highlightTerms)
            pdfView.highlightedSelections = selections.isEmpty ? nil : selections
            pdfView.layoutDocumentView()
            pdfView.go(to: page)
            if let first = selections.first {
                DispatchQueue.main.async {
                    let bounds = first.bounds(for: page).insetBy(dx: -40, dy: -80)
                    pdfView.go(to: bounds, on: page)
                }
            }
            return selections.count
        }

        /// Case- and diacritic-insensitive matches of each term on one page (longest terms first).
        static func selections(on page: PDFPage, terms: [String]) -> [PDFSelection] {
            guard let text = page.string, !text.isEmpty else { return [] }
            let haystack = text as NSString
            var seen = Set<String>()
            let ordered = terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                .sorted { $0.count > $1.count }

            var covered: [NSRange] = []
            var result: [PDFSelection] = []
            for term in ordered {
                var searchRange = NSRange(location: 0, length: haystack.length)
                while searchRange.length > 0, result.count < 60 {
                    let found = haystack.range(
                        of: term,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchRange
                    )
                    guard found.location != NSNotFound else { break }
                    if !covered.contains(where: { NSIntersectionRange($0, found).length > 0 }),
                       let selection = page.selection(for: found) {
                        selection.color = UIColor.systemYellow.withAlphaComponent(0.6)
                        result.append(selection)
                        covered.append(found)
                    }
                    let next = found.location + max(found.length, 1)
                    searchRange = NSRange(location: next, length: haystack.length - next)
                }
            }
            return result
        }
    }
}
