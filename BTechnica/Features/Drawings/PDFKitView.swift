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

/// A filled polygon overlay anchored in PDF page coordinates.
struct PDFAreaOverlay: Equatable {
    var id: UUID?
    var pageIndex: Int
    var vertices: [PDFPoint]
    var color: UIColor
    var opacity: CGFloat
    var isSelected: Bool = false
    /// When true, draw an open polyline (draft) instead of a closed fill.
    var isDraft: Bool = false
}

/// A polygon vertex that can be dragged while editing area geometry.
struct PDFEditableVertex: Equatable {
    var index: Int
    var pageIndex: Int
    var point: PDFPoint
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
///     reported through `onMarkerTap` (used for issue pins);
///   - otherwise taps inside a polygon overlay are reported through `onAreaTap`.
/// - When `editableVertices` is non-empty, a pan near a vertex reports moves
///   through `onVertexDrag` in PDF page coordinates (PDF scroll paused while dragging).
/// - Markers and area polygons are rendered as `PDFAnnotation`s, which PDFKit
///   keeps aligned to the page through zoom and pan.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    var captureEnabled: Bool = false
    var markers: [PDFMarker] = []
    var areas: [PDFAreaOverlay] = []
    /// Vertices that can be dragged (shape-edit mode). Empty disables vertex drag.
    var editableVertices: [PDFEditableVertex] = []
    /// Reports (pageIndex, pointInPDFPageCoordinates) on tap while capturing.
    var onTap: ((Int, PDFPoint) -> Void)? = nil
    /// Reports the marker id when the user taps near a selectable pin.
    var onMarkerTap: ((UUID) -> Void)? = nil
    /// Reports the area id when the user taps inside a selectable polygon.
    var onAreaTap: ((UUID) -> Void)? = nil
    /// Reports (vertexIndex, pointInPDFPageCoordinates) while dragging a vertex.
    var onVertexDrag: ((Int, PDFPoint) -> Void)? = nil

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

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pdfView.addGestureRecognizer(pan)
        context.coordinator.panRecognizer = pan

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
        context.coordinator.panRecognizer?.isEnabled = !editableVertices.isEmpty
        context.coordinator.loadDocumentIfNeeded(url: url, into: pdfView)
        context.coordinator.render(markers: markers, areas: areas, on: pdfView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        var tapRecognizer: UITapGestureRecognizer?
        var panRecognizer: UIPanGestureRecognizer?
        var spinner: UIActivityIndicatorView?
        var errorLabel: UILabel?

        private var addedAnnotations: [(PDFPage, PDFAnnotation)] = []
        private var lastRenderedMarkers: [PDFMarker] = []
        private var lastRenderedAreas: [PDFAreaOverlay] = []
        /// URL of the document currently shown (or being loaded).
        private var loadedURL: URL?
        private var loadID = UUID()
        private var isLoading = false
        private var draggingVertexIndex: Int?
        private var draggingPageIndex: Int?

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
            lastRenderedAreas = []
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
                    self.lastRenderedAreas = []
                    self.render(markers: self.parent.markers, areas: self.parent.areas, on: pdfView)
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

            // Shape edit: taps do not select pins/areas (drag handles vertices instead).
            if !parent.editableVertices.isEmpty { return }

            // Idle: issue pins take priority over area polygons.
            if let id = hitTestMarker(pageIndex: pageIndex, point: pdfPoint, page: page) {
                parent.onMarkerTap?(id)
                return
            }
            if let id = hitTestArea(pageIndex: pageIndex, point: pdfPoint) {
                parent.onAreaTap?(id)
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let pdfView = recognizer.view as? PDFView,
                  let document = pdfView.document else { return }

            switch recognizer.state {
            case .began:
                // Index set in gestureRecognizerShouldBegin.
                setPDFScrollEnabled(false, on: pdfView)
            case .changed:
                guard let index = draggingVertexIndex,
                      let pageIndex = draggingPageIndex,
                      pageIndex >= 0, pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex) else { return }
                let viewPoint = recognizer.location(in: pdfView)
                let pagePoint = PDFPoint(pdfView.convert(viewPoint, to: page))
                parent.onVertexDrag?(index, pagePoint)
            case .ended, .cancelled, .failed:
                draggingVertexIndex = nil
                draggingPageIndex = nil
                setPDFScrollEnabled(true, on: pdfView)
            default:
                break
            }
        }

        private func setPDFScrollEnabled(_ enabled: Bool, on pdfView: PDFView) {
            func visit(_ view: UIView) {
                if let scroll = view as? UIScrollView {
                    scroll.isScrollEnabled = enabled
                }
                for child in view.subviews { visit(child) }
            }
            visit(pdfView)
        }

        /// Returns the id of the nearest labelled marker within hit radius, if any.
        private func hitTestMarker(pageIndex: Int, point: PDFPoint, page: PDFPage) -> UUID? {
            // Visual pins are small; keep a larger, comfortable tap target.
            let radius = max(markerRadius(for: page) * 3.5, 14)
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

        /// Returns the id of the smallest non-draft area containing the point, if any.
        private func hitTestArea(pageIndex: Int, point: PDFPoint) -> UUID? {
            var best: (UUID, Double)?
            for area in parent.areas {
                guard let id = area.id, !area.isDraft, area.pageIndex == pageIndex,
                      area.vertices.count >= 3 else { continue }
                guard pointInPolygon(point, vertices: area.vertices) else { continue }
                let areaSize = abs(polygonArea(area.vertices))
                if best == nil || areaSize < best!.1 {
                    best = (id, areaSize)
                }
            }
            return best?.0
        }

        /// Vertex pan begins only when the touch starts near an editable vertex.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer == panRecognizer else { return true }
            guard !parent.editableVertices.isEmpty,
                  let pdfView = gestureRecognizer.view as? PDFView,
                  let document = pdfView.document else { return false }

            let viewPoint = gestureRecognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return false }
            let pageIndex = document.index(for: page)
            let pdfPoint = PDFPoint(pdfView.convert(viewPoint, to: page))
            guard let index = hitTestEditableVertex(pageIndex: pageIndex, point: pdfPoint, page: page) else {
                return false
            }
            draggingVertexIndex = index
            draggingPageIndex = pageIndex
            return true
        }

        // Let taps coexist with PDFView; vertex pan stays exclusive while active.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gestureRecognizer == panRecognizer || other == panRecognizer {
                return draggingVertexIndex == nil
            }
            return true
        }

        /// Returns the index of the nearest editable vertex within hit radius, if any.
        private func hitTestEditableVertex(pageIndex: Int, point: PDFPoint, page: PDFPage) -> Int? {
            let radius = max(markerRadius(for: page) * 4, 16)
            let radiusSq = radius * radius
            var best: (Int, CGFloat)?

            for vertex in parent.editableVertices where vertex.pageIndex == pageIndex {
                let dx = CGFloat(vertex.point.x - point.x)
                let dy = CGFloat(vertex.point.y - point.y)
                let distSq = dx * dx + dy * dy
                if distSq <= radiusSq {
                    if best == nil || distSq < best!.1 {
                        best = (vertex.index, distSq)
                    }
                }
            }
            return best?.0
        }

        func render(markers: [PDFMarker], areas: [PDFAreaOverlay], on pdfView: PDFView) {
            // Do not record overlays as rendered until a document exists.
            // Otherwise async load + early updateUIView skips pins forever.
            guard let document = pdfView.document else { return }
            guard markers != lastRenderedMarkers || areas != lastRenderedAreas else { return }
            lastRenderedMarkers = markers
            lastRenderedAreas = areas

            clearAnnotations()

            // Areas under pins so issue markers stay visible on overlapping regions.
            for area in areas {
                guard area.pageIndex >= 0, area.pageIndex < document.pageCount,
                      area.vertices.count >= 2,
                      let page = document.page(at: area.pageIndex) else { continue }
                let points = area.vertices.map(\.cgPoint)
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                let pad: CGFloat = area.isSelected ? 4 : 2
                let bounds = CGRect(
                    x: (xs.min() ?? 0) - pad,
                    y: (ys.min() ?? 0) - pad,
                    width: (xs.max() ?? 0) - (xs.min() ?? 0) + pad * 2,
                    height: (ys.max() ?? 0) - (ys.min() ?? 0) + pad * 2
                )
                let annotation = PolygonAreaAnnotation(
                    bounds: bounds,
                    vertices: points,
                    color: area.color,
                    opacity: area.opacity,
                    isSelected: area.isSelected,
                    isDraft: area.isDraft
                )
                page.addAnnotation(annotation)
                addedAnnotations.append((page, annotation))
            }

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
            // Skip when a draft area polyline already connects the draft vertices.
            let hasDraftArea = areas.contains { $0.isDraft }
            let calibrationMarkers = markers.filter { $0.label == nil }
            if !hasDraftArea,
               calibrationMarkers.count == 2,
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
            let side = min(bounds.width, bounds.height)
            // ~0.28% of page, hard-capped — large CAD media boxes must not yield huge pins.
            return max(4.5, min(9, side * 0.0028))
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
        // PDF annotation contexts use PDF page space (origin bottom-left, Y up).
        // UIKit text drawing expects UIKit space (origin top-left, Y down), so without
        // a flip the numbers render upside-down. Circle + label are drawn in a local
        // flipped space; annotation `bounds` (pin position) stay unchanged.
        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: bounds.origin.x, y: bounds.origin.y + bounds.size.height)
        context.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let rect = CGRect(origin: .zero, size: bounds.size)
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
            x: (rect.width - textSize.width) / 2,
            y: (rect.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }
}

/// Filled (or draft) polygon annotation in PDF page coordinates.
final class PolygonAreaAnnotation: PDFAnnotation {
    private let vertices: [CGPoint]
    private let fillColor: UIColor
    private let opacity: CGFloat
    private let isSelected: Bool
    private let isDraft: Bool

    init(bounds: CGRect,
         vertices: [CGPoint],
         color: UIColor,
         opacity: CGFloat,
         isSelected: Bool,
         isDraft: Bool) {
        self.vertices = vertices
        self.fillColor = color
        self.opacity = opacity
        self.isSelected = isSelected
        self.isDraft = isDraft
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        self.color = color
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard vertices.count >= 2 else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let path = CGMutablePath()
        path.move(to: vertices[0])
        for point in vertices.dropFirst() {
            path.addLine(to: point)
        }

        if isDraft {
            if vertices.count >= 3 {
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(fillColor.withAlphaComponent(max(0.12, opacity * 0.45)).cgColor)
                context.fillPath()
            }
            let stroke = CGMutablePath()
            stroke.move(to: vertices[0])
            for point in vertices.dropFirst() {
                stroke.addLine(to: point)
            }
            context.addPath(stroke)
            context.setStrokeColor(fillColor.cgColor)
            context.setLineWidth(isSelected ? 2.5 : 2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.strokePath()
            return
        }

        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(fillColor.withAlphaComponent(opacity).cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(fillColor.cgColor)
        context.setLineWidth(isSelected ? 3 : 1.75)
        context.setLineJoin(CGLineJoin.round)
        context.strokePath()
    }
}

/// Ray-casting point-in-polygon test in PDF page coordinates.
private func pointInPolygon(_ point: PDFPoint, vertices: [PDFPoint]) -> Bool {
    guard vertices.count >= 3 else { return false }
    var inside = false
    var j = vertices.count - 1
    for i in 0..<vertices.count {
        let xi = vertices[i].x, yi = vertices[i].y
        let xj = vertices[j].x, yj = vertices[j].y
        let intersects = ((yi > point.y) != (yj > point.y))
            && (point.x < (xj - xi) * (point.y - yi) / (yj - yi + 0.0000001) + xi)
        if intersects { inside.toggle() }
        j = i
    }
    return inside
}

/// Absolute polygon area (shoelace) used to prefer the smallest overlapping hit.
private func polygonArea(_ vertices: [PDFPoint]) -> Double {
    guard vertices.count >= 3 else { return 0 }
    var sum = 0.0
    for i in 0..<vertices.count {
        let j = (i + 1) % vertices.count
        sum += vertices[i].x * vertices[j].y
        sum -= vertices[j].x * vertices[i].y
    }
    return sum / 2
}
