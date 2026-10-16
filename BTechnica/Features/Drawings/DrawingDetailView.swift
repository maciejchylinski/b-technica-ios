import SwiftUI
import UIKit

/// Opens an imported PDF drawing and hosts scale calibration + issue placement.
///
/// Calibration flow:
///   1. User taps "Set scale".
///   2. App asks the user to tap point A on the PDF.
///   3. App asks the user to tap point B on the PDF.
///   4. App asks for the real distance + unit (mm / cm / m).
///   5. Calibration is stored per drawing/page in PDF page coordinates.
///
/// Issue flow:
///   1. User taps "Add issue".
///   2. App enters placement mode; user taps a point on the PDF.
///   3. Location is stored in PDF page coordinates (drawingId, pageIndex, pdfX, pdfY).
///   4. A simple form collects title / description / optional fields.
///   5. Issue is saved locally; a numbered pin appears on the PDF.
struct DrawingDetailView: View {
    @EnvironmentObject private var store: AppStore
    let drawingId: UUID

    private enum Mode: Equatable {
        case idle
        case calibrating(CalibStep)
        case placingIssue
    }

    private enum CalibStep: Equatable {
        case tapA
        case tapB
        case enterDistance
    }

    @State private var mode: Mode = .idle
    @State private var pointA: (page: Int, point: PDFPoint)?
    @State private var pointB: (page: Int, point: PDFPoint)?
    @State private var showDistanceSheet = false

    /// Pending placement after the user tapped the PDF (before the form is saved).
    @State private var pendingPlacement: (page: Int, point: PDFPoint)?
    @State private var showIssueForm = false

    /// Compact preview shown when an existing pin is tapped.
    @State private var previewIssueId: UUID?
    /// Push Issue Detail from the preview card.
    @State private var issueToOpen: Issue?
    @State private var showDetailsEditor = false

    private var drawing: Drawing? {
        store.data.drawings.first { $0.id == drawingId }
    }

    private var drawingIssues: [Issue] {
        guard let drawing else { return [] }
        return store.issues(for: drawing).sorted { $0.number < $1.number }
    }

    private var previewIssue: Issue? {
        guard let previewIssueId else { return nil }
        return store.issue(id: previewIssueId)
    }

    private var isCapturing: Bool {
        switch mode {
        case .placingIssue: return true
        case .calibrating(.tapA), .calibrating(.tapB): return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if let drawing {
                content(for: drawing)
            } else {
                ContentUnavailableView("Drawing unavailable",
                                       systemImage: "doc.questionmark")
            }
        }
        .navigationDestination(item: $issueToOpen) { issue in
            IssueDetailView(issueId: issue.id)
        }
    }

    @ViewBuilder
    private func content(for drawing: Drawing) -> some View {
        ZStack(alignment: .bottom) {
            PDFKitView(url: store.fileURL(for: drawing),
                       captureEnabled: isCapturing,
                       markers: allMarkers,
                       onTap: handleTap,
                       onMarkerTap: handleMarkerTap)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                if let preview = previewIssue, mode == .idle {
                    IssuePreviewCard(issue: preview) {
                        issueToOpen = preview
                        previewIssueId = nil
                    } onDismiss: {
                        previewIssueId = nil
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                overlay
            }
            .animation(.easeInOut(duration: 0.2), value: previewIssueId)
        }
        .navigationTitle(drawing.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showDistanceSheet, onDismiss: {
            if case .calibrating(.enterDistance) = mode { resetCalibration() }
        }) {
            DistanceInputSheet { value, unit in
                saveCalibration(value: value, unit: unit, for: drawing)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showIssueForm, onDismiss: {
            // Cancelled without saving — leave placement mode cleanly.
            if pendingPlacement != nil {
                pendingPlacement = nil
                mode = .idle
            }
        }) {
            if let pending = pendingPlacement {
                IssueFormView(pageIndex: pending.page, pageCount: drawing.pageCount, point: pending.point) { title, details, discipline, contractor, photos in
                    saveIssue(title: title,
                              details: details,
                              discipline: discipline,
                              contractor: contractor,
                              photos: photos,
                              for: drawing)
                } onCancel: {
                    showIssueForm = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDetailsEditor) {
            DrawingDetailsEditor(drawingId: drawing.id)
                .environmentObject(store)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch mode {
            case .idle:
                Button("Add issue") { startPlacingIssue() }
                Menu {
                    Button("Set scale") { startCalibration() }
                    Button("Edit drawing details") { showDetailsEditor = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            case .placingIssue, .calibrating:
                Button("Cancel", role: .cancel) { cancelActiveMode() }
            }
        }
    }

    // MARK: - Overlay panels

    @ViewBuilder
    private var overlay: some View {
        switch mode {
        case .placingIssue:
            instructionBar("Tap a point on the drawing to place the issue")
        case .calibrating(.tapA):
            instructionBar("Tap point A on the drawing")
        case .calibrating(.tapB):
            instructionBar("Tap point B on the drawing")
        case .idle, .calibrating(.enterDistance):
            EmptyView()
        }
    }

    private func instructionBar(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.title3)
            Text(text)
                .font(.headline)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
        .background(Theme.blue)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
        .shadow(radius: 6, y: 3)
    }

    // MARK: - Markers

    /// Calibration markers + saved issue pins (and a temporary pending pin).
    private var allMarkers: [PDFMarker] {
        var result: [PDFMarker] = []

        for issue in drawingIssues {
            result.append(PDFMarker(pageIndex: issue.pageIndex,
                                    point: issue.pdfPoint,
                                    color: .systemOrange,
                                    label: "\(issue.number)",
                                    id: issue.id))
        }

        if let pending = pendingPlacement, showIssueForm {
            result.append(PDFMarker(pageIndex: pending.page,
                                    point: pending.point,
                                    color: .systemOrange.withAlphaComponent(0.55),
                                    label: "+"))
        }

        if let a = pointA {
            result.append(PDFMarker(pageIndex: a.page, point: a.point, color: .systemBlue))
        }
        if let b = pointB {
            result.append(PDFMarker(pageIndex: b.page, point: b.point, color: .systemGreen))
        }
        return result
    }

    // MARK: - Mode transitions

    private func startPlacingIssue() {
        previewIssueId = nil
        resetCalibrationPoints()
        pendingPlacement = nil
        mode = .placingIssue
    }

    private func startCalibration() {
        previewIssueId = nil
        pendingPlacement = nil
        pointA = nil
        pointB = nil
        mode = .calibrating(.tapA)
    }

    private func cancelActiveMode() {
        switch mode {
        case .placingIssue:
            pendingPlacement = nil
            showIssueForm = false
            mode = .idle
        case .calibrating:
            resetCalibration()
        case .idle:
            break
        }
    }

    private func resetCalibration() {
        mode = .idle
        resetCalibrationPoints()
        showDistanceSheet = false
    }

    private func resetCalibrationPoints() {
        pointA = nil
        pointB = nil
    }

    // MARK: - Tap handling

    private func handleTap(pageIndex: Int, point: PDFPoint) {
        switch mode {
        case .placingIssue:
            pendingPlacement = (pageIndex, point)
            showIssueForm = true
        case .calibrating(.tapA):
            pointA = (pageIndex, point)
            mode = .calibrating(.tapB)
        case .calibrating(.tapB):
            guard let a = pointA, a.page == pageIndex else { return }
            pointB = (pageIndex, point)
            mode = .calibrating(.enterDistance)
            showDistanceSheet = true
        default:
            break
        }
    }

    private func handleMarkerTap(_ id: UUID) {
        guard mode == .idle else { return }
        previewIssueId = id
    }

    // MARK: - Persistence

    private func saveIssue(title: String,
                           details: String,
                           discipline: String?,
                           contractor: String?,
                           photos: [UIImage] = [],
                           for drawing: Drawing) {
        guard let pending = pendingPlacement else { return }
        let issue = Issue(drawingId: drawing.id,
                          pageIndex: pending.page,
                          point: pending.point,
                          number: store.nextIssueNumber(),
                          title: title,
                          details: details,
                          status: .open,
                          discipline: discipline,
                          contractor: contractor)
        store.addIssue(issue)
        for image in photos {
            _ = store.addPhoto(from: image, to: issue.id)
        }
        pendingPlacement = nil
        showIssueForm = false
        mode = .idle
        previewIssueId = issue.id
    }

    private func saveCalibration(value: Double, unit: LengthUnit, for drawing: Drawing) {
        guard let a = pointA, let b = pointB, a.page == b.page else {
            resetCalibration()
            return
        }
        let calibration = PageCalibration(pageIndex: a.page,
                                          pointA: a.point,
                                          pointB: b.point,
                                          enteredValue: value,
                                          enteredUnit: unit)
        store.setCalibration(calibration, for: drawing)
        showDistanceSheet = false
        resetCalibration()
    }
}

/// Compact card shown when the user taps an issue pin on the PDF.
private struct IssuePreviewCard: View {
    let issue: Issue
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 36, height: 36)
                Text("\(issue.number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(issue.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !issue.details.isEmpty {
                    Text(issue.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Tap for details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 3)
    }
}

#Preview {
    NavigationStack {
        DrawingDetailView(drawingId: UUID())
            .environmentObject(AppStore())
    }
}
