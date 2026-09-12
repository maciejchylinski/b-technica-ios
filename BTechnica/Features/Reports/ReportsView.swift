import SwiftUI

/// Simple report preview for the current project, with PDF export via the share sheet.
struct ReportsView: View {
    @EnvironmentObject private var store: AppStore

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

    var body: some View {
        List {
            Section {
                LabeledContent("Project", value: store.data.project.name)
                LabeledContent("Issues", value: "\(sortedIssues.count)")
                LabeledContent("Generated", value: Date().formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Report preview")
            } footer: {
                Text("Creates a PDF of all issues in this project, including photos when available.")
            }

            if sortedIssues.isEmpty {
                Section {
                    Text("No issues yet. Pin an issue on a drawing first.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Issues included") {
                    ForEach(sortedIssues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("#\(issue.number)  \(issue.title)")
                                .font(.headline)
                            HStack(spacing: 6) {
                                Text(issue.status.label)
                                Text("·")
                                Text(drawingName(for: issue))
                                Text("·")
                                Text("Page \(issue.pageIndex + 1)")
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

            Section {
                Button {
                    generateAndShare()
                } label: {
                    if isGenerating {
                        HStack {
                            ProgressView()
                            Text("Generating…")
                        }
                    } else {
                        Label("Export PDF report", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isGenerating)
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
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

    private func drawingName(for issue: Issue) -> String {
        store.data.drawings.first { $0.id == issue.drawingId }?.name ?? "Unknown drawing"
    }

    private func generateAndShare() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil

        let projectName = store.data.project.name
        let generatedDate = Date()
        let blocks: [IssueReportGenerator.IssueBlock] = sortedIssues.map { issue in
            let photos = issue.photos.compactMap { store.image(for: $0) }
            return IssueReportGenerator.IssueBlock(
                number: issue.number,
                title: issue.title,
                details: issue.details,
                status: issue.status.label,
                drawingName: drawingName(for: issue),
                pageNumber: issue.pageIndex + 1,
                photos: photos
            )
        }

        // UIKit PDF drawing uses dynamic colors; keep generation on the main actor.
        do {
            let url = try IssueReportGenerator.writePDF(
                from: .init(projectName: projectName,
                            generatedDate: generatedDate,
                            issues: blocks)
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

#Preview {
    NavigationStack {
        ReportsView()
            .environmentObject(AppStore())
    }
}
