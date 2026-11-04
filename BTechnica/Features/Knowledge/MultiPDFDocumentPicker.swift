import SwiftUI
import UniformTypeIdentifiers

/// Files picker for one or more PDFs. Uses `asCopy`, so the returned URLs are
/// temporary app-owned copies that the caller moves into project storage.
struct MultiPDFDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    /// Removes the picker's temporary copies once they were imported (large PDFs would otherwise double up).
    static func discardTemporaryCopies(_ urls: [URL], fileManager: FileManager = .default) {
        let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().path
        for url in urls where url.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot) {
            try? fileManager.removeItem(at: url)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
