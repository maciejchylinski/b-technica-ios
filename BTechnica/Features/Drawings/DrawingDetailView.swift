import SwiftUI
import UIKit

/// Opens an imported PDF drawing and hosts scale calibration, issue placement,
/// and named polygon areas.
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
///
/// Area flow:
///   1. User taps "Draw area".
///   2. Consecutive taps append polygon vertices (same page, PDF coordinates).
///   3. Finish (≥3 vertices) asks for name + color; Cancel discards the draft.
///   4. Areas render as translucent filled polygons with outlines (PDF annotations).
struct DrawingDetailView: View {
    @EnvironmentObject private var store: AppStore
    let drawingId: UUID

    private enum Mode: Equatable {
        case idle
        case calibrating(CalibStep)
        case placingIssue
        case drawingArea
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

    /// Draft polygon vertices while drawing an area (all on one page).
    @State private var draftAreaPage: Int?
    @State private var draftAreaVertices: [PDFPoint] = []
    @State private var showAreaForm = false
    @State private var areaBeingEdited: Area?
    @State private var showDeleteAreaConfirm = false

    /// Compact preview shown when an existing pin is tapped.
    @State private var previewIssueId: UUID?
    /// Selected area preview (idle tap inside polygon).
    @State private var previewAreaId: UUID?
    /// Session toggle — hides all area overlays without changing stored `isVisible`.
    @State private var showAreaOverlays = true
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

    private var drawingAreas: [Area] {
        guard let drawing else { return [] }
        return store.areas(for: drawing).sorted { $0.createdDate < $1.createdDate }
    }

    private var previewIssue: Issue? {
        guard let previewIssueId else { return nil }
        return store.issue(id: previewIssueId)
    }

    private var previewArea: Area? {
        guard let previewAreaId else { return nil }
        return store.area(id: previewAreaId)
    }

    private var isCapturing: Bool {
        switch mode {
        case .placingIssue, .drawingArea: return true
        case .calibrating(.tapA), .calibrating(.tapB): return true
        default: return false
        }
    }

    private var canFinishArea: Bool {
        draftAreaVertices.count >= 3
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
                       areas: allAreaOverlays,
                       onTap: handleTap,
                       onMarkerTap: handleMarkerTap,
                       onAreaTap: handleAreaTap)
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

                if let area = previewArea, mode == .idle, previewIssue == nil {
                    AreaPreviewCard(area: area) {
                        areaBeingEdited = area
                        showAreaForm = true
                    } onDelete: {
                        showDeleteAreaConfirm = true
                    } onDismiss: {
                        previewAreaId = nil
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                overlay
            }
            .animation(.easeInOut(duration: 0.2), value: previewIssueId)
            .animation(.easeInOut(duration: 0.2), value: previewAreaId)
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
                IssueFormView(
                    drawingId: drawing.id,
                    pageIndex: pending.page,
                    pageCount: drawing.pageCount,
                    point: pending.point
                ) { title, details, discipline, contractor, areaId, photos in
                    saveIssue(title: title,
                              details: details,
                              discipline: discipline,
                              contractor: contractor,
                              areaId: areaId,
                              photos: photos,
                              for: drawing)
                } onCancel: {
                    showIssueForm = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showAreaForm, onDismiss: {
            // Dismiss without save returns to drawing mode with the draft intact.
            areaBeingEdited = nil
        }) {
            if let existing = areaBeingEdited {
                AreaFormView(
                    title: "Edit area",
                    confirmTitle: "Save",
                    initialName: existing.name,
                    initialColor: existing.color
                ) { name, color in
                    store.updateAreaDetails(id: existing.id, name: name, color: color)
                    previewAreaId = existing.id
                    showAreaForm = false
                    areaBeingEdited = nil
                } onCancel: {
                    showAreaForm = false
                    areaBeingEdited = nil
                }
                .presentationDetents([.medium])
            } else {
                AreaFormView(
                    title: "Name area",
                    confirmTitle: "Save area"
                ) { name, color in
                    saveArea(name: name, color: color, for: drawing)
                } onCancel: {
                    showAreaForm = false
                }
                .presentationDetents([.medium])
            }
        }
        .confirmationDialog(
            "Delete this area?",
            isPresented: $showDeleteAreaConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete area", role: .destructive) {
                if let area = previewArea {
                    store.deleteArea(area)
                    previewAreaId = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let area = previewArea {
                Text("“\(area.name)” will be removed from this drawing.")
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
                    Button("Draw area") { startDrawingArea() }
                    Button(showAreaOverlays ? "Hide areas" : "Show areas") {
                        showAreaOverlays.toggle()
                        if !showAreaOverlays { previewAreaId = nil }
                    }
                    Divider()
                    Button("Set scale") { startCalibration() }
                    Button("Edit drawing details") { showDetailsEditor = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            case .drawingArea:
                Button("Finish") { finishDrawingArea() }
                    .disabled(!canFinishArea)
                Button("Cancel", role: .cancel) { cancelActiveMode() }
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
        case .drawingArea:
            instructionBar(
                canFinishArea
                    ? "Tap to add points · Finish when ready (\(draftAreaVertices.count))"
                    : "Tap consecutive points to draw the area (\(draftAreaVertices.count)/3)"
            )
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

    // MARK: - Markers & areas

    /// Calibration markers + saved issue pins (and a temporary pending pin / draft vertices).
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

        if mode == .drawingArea, let page = draftAreaPage {
            for vertex in draftAreaVertices {
                result.append(PDFMarker(pageIndex: page, point: vertex, color: .systemBlue))
            }
        }

        if let a = pointA {
            result.append(PDFMarker(pageIndex: a.page, point: a.point, color: .systemBlue))
        }
        if let b = pointB {
            result.append(PDFMarker(pageIndex: b.page, point: b.point, color: .systemGreen))
        }
        return result
    }

    private var allAreaOverlays: [PDFAreaOverlay] {
        var result: [PDFAreaOverlay] = []

        if showAreaOverlays {
            for area in drawingAreas where area.isVisible {
                result.append(PDFAreaOverlay(
                    id: area.id,
                    pageIndex: area.pageIndex,
                    vertices: area.vertices,
                    color: area.uiColor,
                    opacity: CGFloat(area.opacity),
                    isSelected: area.id == previewAreaId,
                    isDraft: false
                ))
            }
        }

        if mode == .drawingArea,
           let page = draftAreaPage,
           draftAreaVertices.count >= 2 {
            result.append(PDFAreaOverlay(
                id: nil,
                pageIndex: page,
                vertices: draftAreaVertices,
                color: .systemBlue,
                opacity: CGFloat(Area.defaultOpacity),
                isSelected: false,
                isDraft: true
            ))
        }

        return result
    }

    // MARK: - Mode transitions

    private func startPlacingIssue() {
        previewIssueId = nil
        previewAreaId = nil
        resetCalibrationPoints()
        clearAreaDraft()
        pendingPlacement = nil
        mode = .placingIssue
    }

    private func startDrawingArea() {
        previewIssueId = nil
        previewAreaId = nil
        pendingPlacement = nil
        resetCalibrationPoints()
        clearAreaDraft()
        mode = .drawingArea
    }

    private func startCalibration() {
        previewIssueId = nil
        previewAreaId = nil
        pendingPlacement = nil
        clearAreaDraft()
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
        case .drawingArea:
            clearAreaDraft()
            showAreaForm = false
            mode = .idle
        case .calibrating:
            resetCalibration()
        case .idle:
            break
        }
    }

    private func finishDrawingArea() {
        guard canFinishArea else { return }
        areaBeingEdited = nil
        showAreaForm = true
    }

    private func clearAreaDraft() {
        draftAreaPage = nil
        draftAreaVertices = []
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
        case .drawingArea:
            if let draftPage = draftAreaPage, draftPage != pageIndex {
                return
            }
            if draftAreaPage == nil {
                draftAreaPage = pageIndex
            }
            draftAreaVertices.append(point)
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
        previewAreaId = nil
        previewIssueId = id
    }

    private func handleAreaTap(_ id: UUID) {
        guard mode == .idle, showAreaOverlays else { return }
        previewIssueId = nil
        previewAreaId = id
    }

    // MARK: - Persistence

    private func saveIssue(title: String,
                           details: String,
                           discipline: String?,
                           contractor: String?,
                           areaId: UUID?,
                           photos: [UIImage] = [],
                           for drawing: Drawing) {
        guard let pending = pendingPlacement else { return }
        let issue = Issue(drawingId: drawing.id,
                          pageIndex: pending.page,
                          point: pending.point,
                          areaId: areaId,
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

    private func saveArea(name: String, color: String, for drawing: Drawing) {
        guard let page = draftAreaPage, draftAreaVertices.count >= 3 else { return }
        let area = Area(
            projectId: store.projectId,
            drawingId: drawing.id,
            pageIndex: page,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            vertices: draftAreaVertices,
            color: color
        )
        store.addArea(area)
        clearAreaDraft()
        showAreaForm = false
        mode = .idle
        previewAreaId = area.id
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

/// Compact card for a selected polygon area (rename / delete).
private struct AreaPreviewCard: View {
    let area: Area
    var onRename: () -> Void
    var onDelete: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(uiColor: area.uiColor).opacity(area.opacity))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(uiColor: area.uiColor), lineWidth: 2)
                }
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 6) {
                Text(area.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(area.vertices.count) points · page \(area.pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Button("Rename", action: onRename)
                        .font(.caption.weight(.semibold))
                    Button("Delete", role: .destructive, action: onDelete)
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
