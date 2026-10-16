import SwiftUI
import PDFKit

/// A visual marker to draw on the PDF, anchored in PDF page coordinates so it
/// stays glued to the drawing through zoom and pan.
struct PDFMarker: Equatable {
    var pageIndex: Int
    var point: PDFPoint
    var color: UIColor
    /// Optional label drawn inside the marker (e.g. issue number).
    var label: String? = nil
    /// Optional id used for pin hit-testing (e.g. issue id).
    var id: UUID? = nil
}

/// SwiftUI wrapper around `PDFKit.PDFView`.
///
/// - Native pinch-to-zoom and pan come for free from `PDFView`.
/// - `PDFDocument` is loaded off the main thread (construction PDFs can take
///   seconds to parse; doing that in `makeUIView` froze the UI).
/// - Tap handling is centralized here:
///   - when `captureEnabled` is true, taps become PDF page coordinates via
///     `PDFView.page(for:nearest:)` + `PDFView.convert(_:to:)` and are reported
///     through `onTap`;
///   - when capture is off, taps near a labelled marker with an `id` are
///     reported through `onMarkerTap` (used for issue pins).
/// - Markers (and a connecting line when two unlabelled markers share a page)
///   are rendered as `PDFAnnotation`s, which PDFKit keeps aligned to the page.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    var captureEnabled: Bool = false
    var markers: [PDFMarker] = []
    /// Reports (pageIndex, pointInPDFPageCoordinates) on tap while capturing.
    var onTap: ((Int, PDFPoint) -> Void)? = nil
    /// Reports the marker id when the user taps near a selectable pin.
    var onMarkerTap: ((UUID) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.usePageViewController(false)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        pdfView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])

        let errorLabel = UILabel()
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textAlignment = .center
        errorLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        pdfView.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: pdfView.layoutMarginsGuide.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: pdfView.layoutMarginsGuide.trailingAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        pdfView.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap
        context.coordinator.spinner = spinner
        context.coordinator.errorLabel = errorLabel

        // Heavy parse happens off-main; keep makeUIView cheap.
        context.coordinator.loadDocumentIfNeeded(url: url, into: pdfView)

        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        // Tap recognizer stays enabled so idle pin selection works too.
        context.coordinator.tapRecognizer?.isEnabled = true
        context.coordinator.loadDocumentIfNeeded(url: url, into: pdfView)
        context.coordinator.render(markers: markers, on: pdfView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        var tapRecognizer: UITapGestureRecognizer?
        var spinner: UIActivityIndicatorView?
        var errorLabel: UILabel?

        private var addedAnnotations: [(PDFPage, PDFAnnotation)] = []
        private var lastRenderedMarkers: [PDFMarker] = []
        /// URL of the document currently shown (or being loaded).
        private var loadedURL: URL?
        private var loadID = UUID()
        private var isLoading = false

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        /// Loads `PDFDocument` on a background queue once per URL.
        func loadDocumentIfNeeded(url: URL, into pdfView: PDFView) {
            if loadedURL == url, pdfView.document != nil || isLoading {
                return
            }

            let loadID = UUID()
            self.loadID = loadID
            loadedURL = url
            isLoading = true
            lastRenderedMarkers = []
            clearAnnotations()

            pdfView.document = nil
            errorLabel?.isHidden = true
            errorLabel?.text = nil
            spinner?.startAnimating()

            let fileName = url.lastPathComponent
            let started = CFAbsoluteTimeGetCurrent()
            print("[PDFKitView] load start (background): \(fileName)")

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let document = PDFDocument(url: url)
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.loadID == loadID else { return }

                    self.isLoading = false
                    self.spinner?.stopAnimating()

                    guard let document else {
                        print("[PDFKitView] load failed in \(String(format: "%.2f", elapsed))s: \(fileName)")
                        self.errorLabel?.text = "Could not open this PDF."
                        self.errorLabel?.isHidden = false
                        return
                    }

                    print("[PDFKitView] load done in \(String(format: "%.2f", elapsed))s, pages=\(document.pageCount): \(fileName)")
                    pdfView.document = document
                    // Force annotation pass: updateUIView may have "rendered" while
                    // document was still nil and skipped drawing pins.
                    self.lastRenderedMarkers = []
                    self.render(markers: self.parent.markers, on: pdfView)
                }
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView = recognizer.view as? PDFView,
                  let document = pdfView.document else { return }

            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            // Convert screen/view coordinates into this page's PDF coordinates.
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let pageIndex = document.index(for: page)
            let pdfPoint = PDFPoint(pagePoint)

            if parent.captureEnabled {
                parent.onTap?(pageIndex, pdfPoint)
                return
            }

            // Idle: hit-test against selectable (id-bearing) markers on this page.
            if let id = hitTest(pageIndex: pageIndex, point: pdfPoint, page: page) {
                parent.onMarkerTap?(id)
            }
        }

        /// Returns the id of the nearest labelled marker within hit radius, if any.
        private func hitTest(pageIndex: Int, point: PDFPoint, page: PDFPage) -> UUID? {
            let radius = markerRadius(for: page) * 2.5
            let radiusSq = radius * radius
            var best: (UUID, CGFloat)?

            for marker in parent.markers {
                guard let id = marker.id, marker.pageIndex == pageIndex else { continue }
                let dx = CGFloat(marker.point.x - point.x)
                let dy = CGFloat(marker.point.y - point.y)
                let distSq = dx * dx + dy * dy
                if distSq <= radiusSq {
                    if best == nil || distSq < best!.1 {
                        best = (id, distSq)
                    }
                }
            }
            return best?.0
        }

        // Let our tap coexist with PDFView's own gesture recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func render(markers: [PDFMarker], on pdfView: PDFView) {
            // Do not record markers as rendered until a document exists.
            // Otherwise async load + early updateUIView skips pins forever.
            guard let document = pdfView.document else { return }
            guard markers != lastRenderedMarkers else { return }
            lastRenderedMarkers = markers

            clearAnnotations()

            for marker in markers {
                guard marker.pageIndex >= 0, marker.pageIndex < document.pageCount,
                      let page = document.page(at: marker.pageIndex) else { continue }
                let radius = markerRadius(for: page)
                let rect = CGRect(x: marker.point.x - radius,
                                  y: marker.point.y - radius,
                                  width: radius * 2,
                                  height: radius * 2)

                if let label = marker.label {
                    let pin = NumberedPinAnnotation(bounds: rect,
                                                    numberText: label,
                                                    color: marker.color)
                    page.addAnnotation(pin)
                    addedAnnotations.append((page, pin))
                } else {
                    let annotation = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
                    annotation.color = marker.color
                    annotation.interiorColor = marker.color.withAlphaComponent(0.35)
                    annotation.border = PDFBorder()
                    annotation.border?.lineWidth = max(1.5, radius * 0.25)
                    page.addAnnotation(annotation)
                    addedAnnotations.append((page, annotation))
                }
            }

            // Draw a connecting line if exactly two unlabelled markers share a page
            // (calibration A↔B). Labelled issue pins must not get a joining line.
            let calibrationMarkers = markers.filter { $0.label == nil }
            if calibrationMarkers.count == 2,
               calibrationMarkers[0].pageIndex == calibrationMarkers[1].pageIndex,
               let page = document.page(at: calibrationMarkers[0].pageIndex) {
                let a = calibrationMarkers[0].point.cgPoint
                let b = calibrationMarkers[1].point.cgPoint
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(a.x - b.x), height: abs(a.y - b.y))
                    .insetBy(dx: -1, dy: -1)
                let line = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
                line.startPoint = CGPoint(x: a.x - rect.minX, y: a.y - rect.minY)
                line.endPoint = CGPoint(x: b.x - rect.minX, y: b.y - rect.minY)
                line.color = calibrationMarkers[0].color
                line.border = PDFBorder()
                line.border?.lineWidth = max(1.5, markerRadius(for: page) * 0.2)
                page.addAnnotation(line)
                addedAnnotations.append((page, line))
            }
        }

        private func clearAnnotations() {
            for (page, annotation) in addedAnnotations {
                page.removeAnnotation(annotation)
            }
            addedAnnotations.removeAll()
        }

        private func markerRadius(for page: PDFPage) -> CGFloat {
            let bounds = page.bounds(for: .mediaBox)
            return max(8, min(bounds.width, bounds.height) * 0.014)
        }
    }
}

/// Custom PDF annotation that draws a filled circle with a centered number.
/// Drawn in page coordinates so it stays locked to the PDF under zoom/pan.
final class NumberedPinAnnotation: PDFAnnotation {
    private let numberText: String
    private let fillColor: UIColor

    init(bounds: CGRect, numberText: String, color: UIColor) {
        self.numberText = numberText
        self.fillColor = color
        super.init(bounds: bounds, forType: .circle, withProperties: nil)
        self.color = color
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let rect = bounds
        let path = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        fillColor.setFill()
        path.fill()
        UIColor.white.setStroke()
        path.lineWidth = max(1.0, min(rect.width, rect.height) * 0.08)
        path.stroke()

        let fontSize = min(rect.width, rect.height) * 0.48
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]
        let text = numberText as NSString
        let textSize = text.size(withAttributes: attrs)
        let textRect = CGRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }
}
