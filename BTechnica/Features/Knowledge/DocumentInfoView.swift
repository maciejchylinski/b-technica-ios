import SwiftUI

/// Metadata editor + file and indexing details for one library document.
struct DocumentInfoView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let documentId: UUID
    var showsDoneButton: Bool = false
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var draft = Draft()
    @State private var loadedDraft = Draft()
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private struct Draft: Equatable {
        var name = ""
        var category: DocumentCategory = .other
        var descriptionText = ""
        var revision = ""
        var hasRevisionDate = false
        var revisionDate = Date()
    }

    private var document: ProjectDocument? { knowledge.document(id: documentId) }
    private var isDirty: Bool { didLoad && draft != loadedDraft }

    var body: some View {
        Group {
            if let document {
                form(document)
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc")
            }
        }
        .navigationTitle("Document Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDirty ? "Cancel" : "Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isDirty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("knowledgeDocumentSaveButton")
            }
        }
        .onAppear(perform: loadDraftIfNeeded)
        .alert(
            "Document",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \u{201C}\(document?.name ?? "document")\u{201D}?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete document", role: .destructive) { delete() }
        } message: {
            Text("The PDF and its search index are removed from this device. This cannot be undone.")
        }
    }

    private func form(_ document: ProjectDocument) -> some View {
        Form {
            Section("Details") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("knowledgeDocumentNameField")
                Picker("Category", selection: $draft.category) {
                    ForEach(DocumentCategory.allCases) { category in
                        Label(category.title, systemImage: category.systemImage).tag(category)
                    }
                }
                TextField("Description", text: $draft.descriptionText, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section("Revision") {
                TextField("Revision (e.g. B, 02)", text: $draft.revision)
                    .textInputAutocapitalization(.characters)
                Toggle("Revision date", isOn: $draft.hasRevisionDate)
                if draft.hasRevisionDate {
                    DatePicker("Date", selection: $draft.revisionDate, displayedComponents: .date)
                }
            }

            Section("File") {
                LabeledContent("Original file", value: document.originalFileName)
                LabeledContent("Size", value: KnowledgeFormat.fileSize(document.fileSizeBytes))
                LabeledContent("Pages", value: "\(document.pageCount)")
                LabeledContent("Uploaded", value: document.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let checksum = document.checksumSHA256 {
                    LabeledContent("SHA-256", value: String(checksum.prefix(16)) + "…")
                        .font(.footnote.monospaced())
                }
                if !knowledge.isFileAvailable(document) {
                    Label("The PDF file is missing from this device.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                DocumentIndexBadge(
                    document: document,
                    progress: knowledge.indexingProgress[document.id],
                    fileAvailable: knowledge.isFileAvailable(document)
                )
                if document.indexStatus == .indexed {
                    if let summary = document.extractionSummary {
                        LabeledContent("Text source", value: summary.title)
                    }
                    LabeledContent("Pages with text layer", value: "\(document.textPageCount)")
                    LabeledContent("Pages read by OCR", value: "\(document.ocrPageCount)")
                    if let indexedAt = document.indexedAt {
                        LabeledContent("Indexed", value: indexedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let error = document.indexError, document.indexStatus == .failed {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if document.indexStatus == .failed {
                    Button {
                        knowledge.retryIndexing(id: document.id)
                    } label: {
                        Label("Retry indexing", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("knowledgeRetryIndexButton")
                } else if document.indexStatus == .indexed {
                    Button {
                        knowledge.retryIndexing(id: document.id, force: true)
                    } label: {
                        Label("Re-index document", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Search index")
            } footer: {
                Text("Text is extracted on this device. Scanned pages are read with on-device OCR.")
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete document", systemImage: "trash")
                }
            }
        }
    }

    private func loadDraftIfNeeded() {
        guard !didLoad, let document else { return }
        let loaded = Draft(
            name: document.name,
            category: document.category,
            descriptionText: document.descriptionText,
            revision: document.revision ?? "",
            hasRevisionDate: document.revisionDate != nil,
            revisionDate: document.revisionDate ?? Date()
        )
        draft = loaded
        loadedDraft = loaded
        didLoad = true
    }

    private func save() {
        if let message = knowledge.updateDocument(
            id: documentId,
            name: draft.name,
            category: draft.category,
            descriptionText: draft.descriptionText,
            revision: draft.revision,
            revisionDate: draft.hasRevisionDate ? draft.revisionDate : nil
        ) {
            errorMessage = message
            return
        }
        loadedDraft = draft
        if showsDoneButton { dismiss() }
    }

    private func delete() {
        if let message = knowledge.deleteDocument(id: documentId) {
            errorMessage = message
            return
        }
        if let onDeleted {
            onDeleted()
        } else {
            dismiss()
        }
    }
}
