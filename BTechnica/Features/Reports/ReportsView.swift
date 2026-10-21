import SwiftUI

/// Simple report preview for the current project, with PDF export via the share sheet.
struct ReportsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var statusFilter: StatusFilter = .all
    @State private var drawingFilter: DrawingFilter = .all
    @State private var contractorFilter: StringFilter = .all
    @State private var disciplineFilter: StringFilter = .all
    @State private var isGenerating = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    private var sortedIssues: [Issue] {
        store.data.issues.sorted { lhs, rhs in
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.createdDate < rhs.createdDate
        }
    }

    private var filteredIssues: [Issue] {
        sortedIssues.filter { issue in
            statusMatches(issue)
                && drawingMatches(issue)
                && stringMatches(issue.contractor, filter: contractorFilter)
                && stringMatches(issue.discipline, filter: disciplineFilter)
        }
    }

    private var filteredPhotoCount: Int {
        filteredIssues.reduce(0) { $0 + $1.photos.count }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let status = statusFilter.status {
            parts.append("Status: \(status.label)")
        }
        if case .drawing(let id) = drawingFilter {
            let name = store.data.drawings.first { $0.id == id }?.name ?? "Selected drawing"
            parts.append("Drawing: \(name)")
        }
        if let contractorLabel = contractorFilter.summaryLabel(noun: "Contractor") {
            parts.append(contractorLabel)
        }
        if let disciplineLabel = disciplineFilter.summaryLabel(noun: "Discipline") {
            parts.append(disciplineLabel)
        }
        return parts.isEmpty ? "All issues" : parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            Section {
                Picker("Status", selection: $statusFilter) {
                    Text("All").tag(StatusFilter.all)
                    ForEach(IssueStatus.allCases) { status in
                        Text(status.label).tag(StatusFilter.status(status))
                    }
                }

                Picker("Drawing", selection: $drawingFilter) {
                    Text("All drawings").tag(DrawingFilter.all)
                    ForEach(drawingsInIssues) { drawing in
                        Text(drawing.name).tag(DrawingFilter.drawing(drawing.id))
                    }
                }

                Picker("Contractor", selection: $contractorFilter) {
                    Text("All contractors").tag(StringFilter.all)
                    if hasBlank(store.data.issues.map(\.contractor)) {
                        Text("No contractor").tag(StringFilter.none)
                    }
                    ForEach(contractorNames, id: \.self) { name in
                        Text(name).tag(StringFilter.value(name))
                    }
                }

                Picker("Discipline", selection: $disciplineFilter) {
                    Text("All disciplines").tag(StringFilter.all)
                    if hasBlank(store.data.issues.map(\.discipline)) {
                        Text("No discipline").tag(StringFilter.none)
                    }
                    ForEach(disciplineNames, id: \.self) { name in
                        Text(name).tag(StringFilter.value(name))
                    }
                }
            } header: {
                Text("Filters")
            } footer: {
                Text("Preview and export use these filters.")
            }

            Section {
                LabeledContent("Project", value: store.data.project.name)
                LabeledContent("Issues", value: "\(filteredIssues.count)")
                LabeledContent("Photos", value: "\(filteredPhotoCount)")
                LabeledContent("Filters", value: filterSummary)
                LabeledContent("Generated", value: Date().formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Report preview")
            } footer: {
                Text("Creates a PDF of the matching issues, including photos when available.")
            }

            if store.data.issues.isEmpty {
                Section {
                    Text("No issues yet. Pin an issue on a drawing first.")
                        .foregroundStyle(.secondary)
                }
            } else if filteredIssues.isEmpty {
                Section {
                    Text("No issues match the current filters. Change a filter to include issues in the report.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Issues included") {
                    ForEach(filteredIssues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("#\(issue.number)  \(issue.title)")
                                .font(.headline)
                            HStack(spacing: 6) {
                                Text(issue.status.label)
                                Text("·")
                                Text(drawingLabel(for: issue))
                                if let pageLabel = drawing(for: issue)?.pageLabel(for: issue.pageIndex) {
                                    Text("·")
                                    Text(pageLabel)
                                }
                                if !issue.photos.isEmpty {
                                    Text("·")
                                    Label("\(issue.photos.count)", systemImage: "photo")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isGenerating {
                    ProgressView()
                } else {
                    Button("Export PDF") {
                        generateAndShare()
                    }
                    .disabled(filteredIssues.isEmpty)
                    .accessibilityIdentifier("exportPDFReport")
                }
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            shareURL = nil
        }) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("Export failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var drawingsInIssues: [Drawing] {
        let ids = Set(store.data.issues.map(\.drawingId))
        return store.data.drawings
            .filter { ids.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var contractorNames: [String] {
        let fromIssues = store.data.issues.map(\.contractor)
        let fromDictionary = store.data.contractors.map { Optional($0.name) }
        return uniqueNonEmptyValues(fromIssues + fromDictionary)
    }

    private var disciplineNames: [String] {
        let fromIssues = store.data.issues.map(\.discipline)
        let fromDictionary = store.data.disciplines.map { Optional($0.name) }
        return uniqueNonEmptyValues(fromIssues + fromDictionary)
    }

    private func statusMatches(_ issue: Issue) -> Bool {
        guard let status = statusFilter.status else { return true }
        return issue.status == status
    }

    private func drawingMatches(_ issue: Issue) -> Bool {
        guard case .drawing(let id) = drawingFilter else { return true }
        return issue.drawingId == id
    }

    private func stringMatches(_ value: String?, filter: StringFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .none:
            return isBlank(value)
        case .value(let name):
            return value == name
        }
    }

    private func uniqueNonEmptyValues(_ values: [String?]) -> [String] {
        let names = values.compactMap { value -> String? in
            guard let value, !isBlank(value) else { return nil }
            return value
        }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func hasBlank(_ values: [String?]) -> Bool {
        values.contains { isBlank($0) }
    }

    private func isBlank(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private func drawingName(for issue: Issue) -> String {
        store.data.drawings.first { $0.id == issue.drawingId }?.name ?? "Unknown drawing"
    }

    private func drawingLabel(for issue: Issue) -> String {
        store.data.drawings.first { $0.id == issue.drawingId }?.issueReferenceLabel ?? "Unknown drawing"
    }

    private func drawing(for issue: Issue) -> Drawing? {
        store.data.drawings.first { $0.id == issue.drawingId }
    }

    private func generateAndShare() {
        guard !isGenerating, !filteredIssues.isEmpty else { return }
        isGenerating = true
        errorMessage = nil

        let projectName = store.data.project.name
        let generatedDate = Date()
        let summary = filterSummary
        let blocks: [IssueReportGenerator.IssueBlock] = filteredIssues.map { issue in
            let photos = issue.photos.compactMap { store.image(for: $0) }
            let drawing = drawing(for: issue)
            let areaName = issue.areaId.flatMap { store.area(id: $0)?.name }
            return IssueReportGenerator.IssueBlock(
                number: issue.number,
                title: issue.title,
                details: issue.details,
                status: issue.status.label,
                drawingName: drawing?.name ?? "Unknown drawing",
                drawingRevision: drawing?.displayRevision,
                drawingLocation: drawing?.displayLocation,
                areaName: areaName,
                contractor: issue.contractor,
                discipline: issue.discipline,
                pageNumber: issue.pageIndex + 1,
                drawingPageCount: drawing?.pageCount ?? 1,
                photos: photos
            )
        }

        // UIKit PDF drawing uses dynamic colors; keep generation on the main actor.
        do {
            let url = try IssueReportGenerator.writePDF(
                from: .init(projectName: projectName,
                            generatedDate: generatedDate,
                            issues: blocks,
                            filterSummary: summary)
            )
            isGenerating = false
            shareURL = url
            showShareSheet = true
        } catch {
            isGenerating = false
            errorMessage = error.localizedDescription
        }
    }
}

private enum StatusFilter: Hashable {
    case all
    case status(IssueStatus)

    var status: IssueStatus? {
        if case .status(let status) = self { return status }
        return nil
    }
}

private enum DrawingFilter: Hashable {
    case all
    case drawing(UUID)
}

private enum StringFilter: Hashable {
    case all
    case none
    case value(String)

    func summaryLabel(noun: String) -> String? {
        switch self {
        case .all:
            return nil
        case .none:
            return "\(noun): No \(noun.lowercased())"
        case .value(let name):
            return "\(noun): \(name)"
        }
    }
}

#Preview {
    NavigationStack {
        ReportsView()
            .environmentObject(AppStore())
    }
}
