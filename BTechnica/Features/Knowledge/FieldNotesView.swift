import SwiftUI

/// Project field notes, most recently edited first.
struct FieldNotesListView: View {
    @ObservedObject var knowledge: KnowledgeStore

    @State private var showingNewNote = false
    @State private var pendingDelete: ProjectNote?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if knowledge.notes.isEmpty {
                ContentUnavailableView {
                    Label("No field notes yet", systemImage: "note.text")
                } description: {
                    Text("Write down observations, measurements and agreements from site. Notes are searchable together with documents.")
                } actions: {
                    Button {
                        showingNewNote = true
                    } label: {
                        Text("New Note")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 40)
                    .accessibilityIdentifier("knowledgeNewNoteButton")
                }
            } else {
                List {
                    ForEach(knowledge.notes) { note in
                        NavigationLink(value: KnowledgeRoute.note(note.id)) {
                            FieldNoteRow(note: note)
                        }
                        .accessibilityIdentifier("knowledgeNoteRow")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = note
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = note
                            } label: {
                                Label("Delete note", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New note")
                .accessibilityIdentifier("knowledgeAddNoteButton")
            }
        }
        .sheet(isPresented: $showingNewNote) {
            NavigationStack {
                NoteEditorView(knowledge: knowledge, noteId: nil)
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.displayTitle ?? "note")\u{201D}?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { note in
            Button("Delete note", role: .destructive) {
                pendingDelete = nil
                if let message = knowledge.deleteNote(id: note.id) { errorMessage = message }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .alert(
            "Field Notes",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct FieldNoteRow: View {
    let note: ProjectNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(2)
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let category = note.category {
                    Text(category.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.blue)
                }
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Create (`noteId == nil`, presented in a sheet) or edit an existing note (pushed).
/// Existing notes also save when leaving the screen so edits are not lost on site.
struct NoteEditorView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let noteId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var noteBody = ""
    @State private var category: NoteCategory?
    @State private var original: (String, String, NoteCategory?) = ("", "", nil)
    @State private var didLoad = false
    @State private var didDelete = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @FocusState private var bodyFocused: Bool

    private var isNew: Bool { noteId == nil }
    private var existing: ProjectNote? { noteId.flatMap(knowledge.note(id:)) }
    private var isDirty: Bool {
        title != original.0 || noteBody != original.1 || category != original.2
    }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !isNew && existing == nil && !didDelete {
                ContentUnavailableView("Note unavailable", systemImage: "note.text")
            } else {
                editor
            }
        }
        .navigationTitle(isNew ? "New Note" : "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if save() { dismiss() }
                }
                .disabled(!canSave || (!isNew && !isDirty))
                .accessibilityIdentifier("knowledgeSaveNoteButton")
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            if !isNew, !didDelete, isDirty, canSave { _ = save() }
        }
        .alert(
            "Note",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) { delete() }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var editor: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                    .font(.headline)
                    .submitLabel(.next)
                    .onSubmit { bodyFocused = true }
                    .accessibilityIdentifier("knowledgeNoteTitleField")
                Picker("Category", selection: $category) {
                    Text("None").tag(NoteCategory?.none)
                    ForEach(NoteCategory.allCases) { category in
                        Text(category.title).tag(NoteCategory?.some(category))
                    }
                }
            }
            Section("Note") {
                TextEditor(text: $noteBody)
                    .frame(minHeight: 240)
                    .focused($bodyFocused)
                    .accessibilityIdentifier("knowledgeNoteBodyEditor")
            }
            if let existing {
                Section {
                    LabeledContent("Created", value: existing.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Updated", value: existing.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete note", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else { return }
        title = existing.title
        noteBody = existing.body
        category = existing.category
        original = (existing.title, existing.body, existing.category)
    }

    private func save() -> Bool {
        switch knowledge.saveNote(id: noteId, title: title, body: noteBody, category: category) {
        case .success(let note):
            title = note.title
            noteBody = note.body
            original = (note.title, note.body, note.category)
            return true
        case .failure(let error):
            errorMessage = error.message
            return false
        }
    }

    private func delete() {
        guard let noteId else { return }
        if let message = knowledge.deleteNote(id: noteId) {
            errorMessage = message
            return
        }
        didDelete = true
        dismiss()
    }
}
