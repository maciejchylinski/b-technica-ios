import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Simple form for creating an issue after the user tapped a point on the PDF.
/// Photos stay in memory until Save; Cancel leaves no orphan files on disk.
struct IssueFormView: View {
    @EnvironmentObject private var store: AppStore

    let pageIndex: Int
    let pageCount: Int
    let point: PDFPoint
    var onSave: (String, String, String?, String?, [UIImage]) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var details: String = ""
    /// Empty string means "None".
    @State private var selectedDisciplineName: String = ""
    /// Empty string means "None".
    @State private var selectedContractorName: String = ""
    @State private var showAddDiscipline = false
    @State private var showAddContractor = false
    @State private var newDisciplineName = ""
    @State private var newContractorName = ""

    @State private var pendingPhotos: [PendingFormPhoto] = []
    @State private var showAddPhotoOptions = false
    @State private var showCamera = false
    @State private var showCameraUnavailable = false
    @State private var showLibraryPicker = false
    @State private var libraryItem: PhotosPickerItem?

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedDisciplines: [Discipline] {
        store.data.disciplines.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var sortedContractors: [Contractor] {
        store.data.contractors.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("Description", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Issue")
                } footer: {
                    if pageCount > 1 {
                        Text("Status defaults to Open. The pin is saved on page \(pageIndex + 1) of the drawing.")
                    } else {
                        Text("Status defaults to Open. The pin is saved on this drawing.")
                    }
                }

                Section {
                    if pendingPhotos.isEmpty {
                        Text("No photos yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(pendingPhotos) { item in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: item.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Button {
                                            pendingPhotos.removeAll { $0.id == item.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.55))
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button {
                        showAddPhotoOptions = true
                    } label: {
                        Label("Add photo", systemImage: "photo.badge.plus")
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Photos are saved with the issue. Cancel discards them.")
                }

                Section {
                    if sortedDisciplines.isEmpty {
                        Text("No disciplines yet.")
                            .foregroundStyle(.secondary)
                        Button("Add discipline") {
                            newDisciplineName = ""
                            showAddDiscipline = true
                        }
                    } else {
                        Picker("Discipline", selection: $selectedDisciplineName) {
                            Text("None").tag("")
                            ForEach(sortedDisciplines) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Add discipline") {
                            newDisciplineName = ""
                            showAddDiscipline = true
                        }
                    }
                } header: {
                    Text("Discipline / category")
                } footer: {
                    Text("Managed under More → Disciplines.")
                }

                Section {
                    if sortedContractors.isEmpty {
                        Text("No contractors yet.")
                            .foregroundStyle(.secondary)
                        Button("Add contractor") {
                            newContractorName = ""
                            showAddContractor = true
                        }
                    } else {
                        Picker("Contractor", selection: $selectedContractorName) {
                            Text("None").tag("")
                            ForEach(sortedContractors) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Add contractor") {
                            newContractorName = ""
                            showAddContractor = true
                        }
                    }
                } header: {
                    Text("Contractor")
                } footer: {
                    Text("Managed under More → Contractors.")
                }
            }
            .navigationTitle("New issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Add photo", isPresented: $showAddPhotoOptions, titleVisibility: .visible) {
                Button("Camera") { openCamera() }
                Button("Photo Library") { showLibraryPicker = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showLibraryPicker,
                          selection: $libraryItem,
                          matching: .images)
            .onChange(of: libraryItem) { _, newItem in
                Task { await importLibraryPhoto(newItem) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    pendingPhotos.append(PendingFormPhoto(image: image))
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .alert("Camera unavailable", isPresented: $showCameraUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This device cannot take photos. Use the photo library instead.")
            }
            .alert("Add discipline", isPresented: $showAddDiscipline) {
                TextField("Name", text: $newDisciplineName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    if let added = store.addDiscipline(name: newDisciplineName) {
                        selectedDisciplineName = added.name
                    }
                }
            } message: {
                Text("Creates a local discipline you can reuse on issues.")
            }
            .alert("Add contractor", isPresented: $showAddContractor) {
                TextField("Name", text: $newContractorName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    if let added = store.addContractor(name: newContractorName) {
                        selectedContractorName = added.name
                    }
                }
            } message: {
                Text("Creates a local contractor you can reuse on issues.")
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let discipline = selectedDisciplineName.isEmpty ? nil : selectedDisciplineName
        let contractor = selectedContractorName.isEmpty ? nil : selectedContractorName
        let images = pendingPhotos.map(\.image)
        onSave(trimmedTitle, trimmedDetails, discipline, contractor, images)
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showCameraUnavailable = true
        }
    }

    private func importLibraryPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { libraryItem = nil }
        do {
            let picked = try await item.loadTransferable(type: FormPickedImage.self)
            guard let image = picked?.image else { return }
            pendingPhotos.append(PendingFormPhoto(image: image))
        } catch {
            print("[IssueForm] Failed to import library photo: \(error)")
        }
    }
}

private struct PendingFormPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct FormPickedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FormPickedImage(image: image)
        }
    }
}
