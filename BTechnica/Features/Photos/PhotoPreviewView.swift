import SwiftUI

/// Full-screen, swipeable photo viewer with pinch / double-tap zoom.
/// Documentation photos can be edited or deleted here; issue photos are read-only.
struct PhotoPreviewView: View {
    let entries: [GalleryEntry]
    let startId: UUID
    var isMissing: (GalleryEntry) -> Bool
    var onEdit: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var onClose: () -> Void

    @State private var currentId: UUID
    @State private var showChrome = true
    @State private var confirmDelete = false
    @State private var deleted: Set<UUID> = []

    init(entries: [GalleryEntry], startId: UUID,
         isMissing: @escaping (GalleryEntry) -> Bool,
         onEdit: @escaping (UUID) -> Void,
         onDelete: @escaping (UUID) -> Void,
         onClose: @escaping () -> Void) {
        self.entries = entries
        self.startId = startId
        self.isMissing = isMissing
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onClose = onClose
        _currentId = State(initialValue: startId)
    }

    private var visible: [GalleryEntry] { entries.filter { !deleted.contains($0.id) } }
    private var current: GalleryEntry? { visible.first { $0.id == currentId } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentId) {
                ForEach(visible) { entry in
                    ZoomablePhoto(entry: entry, missing: isMissing(entry))
                        .tag(entry.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation { showChrome.toggle() } }

            if showChrome {
                VStack {
                    topBar
                    Spacer()
                    if let current { caption(current) }
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showChrome)
        .confirmationDialog("Delete photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete photo", role: .destructive) { deleteCurrent() }
        } message: {
            Text("The photo and its local file are removed from this project. This cannot be undone.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button("Done") { onClose() }
                .fontWeight(.semibold)
            Spacer()
            if let index = visible.firstIndex(where: { $0.id == currentId }) {
                Text("\(index + 1) of \(visible.count)")
                    .font(.subheadline)
            }
            Spacer()
            if let current, current.kind == .documentation {
                Button { onEdit(current.id) } label: { Image(systemName: "pencil.circle") }
                    .accessibilityLabel("Edit details")
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete photo")
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(minHeight: Theme.touchTarget)
        .background(.black.opacity(0.4))
    }

    private func caption(_ entry: GalleryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            if !entry.subtitle.isEmpty {
                Text(entry.subtitle).font(.caption)
            }
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.subheadline)
                    .lineLimit(4)
            }
            if entry.kind == .documentation {
                Text("Local only · not synced")
                    .font(.caption2)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.black.opacity(0.45))
    }

    private func deleteCurrent() {
        guard let current else { return }
        let index = visible.firstIndex(where: { $0.id == current.id }) ?? 0
        onDelete(current.id)
        deleted.insert(current.id)
        let remaining = visible
        if remaining.isEmpty {
            onClose()
        } else {
            currentId = remaining[min(index, remaining.count - 1)].id
        }
    }
}

private struct ZoomablePhoto: View {
    let entry: GalleryEntry
    let missing: Bool

    @State private var image: UIImage?
    @State private var loaded = false
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnify)
                    .simultaneousGesture(scale > 1 ? pan : nil)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) {
                            if scale > 1 { reset() } else { scale = 2.5; baseScale = 2.5 }
                        }
                    }
            } else if loaded || missing {
                ContentUnavailableView(
                    "Photo unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The image file is missing or damaged on this device.")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.fileURL) {
            guard !missing else { loaded = true; return }
            let url = entry.fileURL
            image = await Task.detached(priority: .userInitiated) {
                PhotoImageProcessing.downsampledImage(at: url, maxPixelSize: 2560)
            }.value
            loaded = true
        }
        .onDisappear { reset() }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = max(1, min(6, baseScale * value.magnification)) }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 { withAnimation { reset() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
