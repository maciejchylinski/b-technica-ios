import SwiftUI

/// Full issue detail screen opened from a pin preview or the Issues list.
struct IssueDetailView: View {
    @EnvironmentObject private var store: AppStore
    let issueId: UUID

    private var issue: Issue? {
        store.issue(id: issueId)
    }

    private var drawingName: String {
        guard let issue,
              let drawing = store.data.drawings.first(where: { $0.id == issue.drawingId }) else {
            return "Unknown drawing"
        }
        return drawing.name
    }

    var body: some View {
        Group {
            if let issue {
                List {
                    Section {
                        LabeledContent("Number", value: "#\(issue.number)")
                        LabeledContent("Status", value: issue.status.label)
                        LabeledContent("Drawing", value: drawingName)
                        LabeledContent("Page", value: "\(issue.pageIndex + 1)")
                    }

                    Section("Details") {
                        Text(issue.title)
                            .font(.headline)
                        if issue.details.isEmpty {
                            Text("No description")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(issue.details)
                        }
                    }

                    Section("Location (PDF)") {
                        LabeledContent("pdfX", value: formatted(issue.pdfX))
                        LabeledContent("pdfY", value: formatted(issue.pdfY))
                    }

                    if issue.discipline != nil || issue.contractor != nil {
                        Section("Classification") {
                            if let discipline = issue.discipline, !discipline.isEmpty {
                                LabeledContent("Discipline", value: discipline)
                            }
                            if let contractor = issue.contractor, !contractor.isEmpty {
                                LabeledContent("Contractor", value: contractor)
                            }
                        }
                    }

                    Section {
                        LabeledContent("Created", value: issue.createdDate.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .navigationTitle(issue.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Issue unavailable",
                                       systemImage: "exclamationmark.bubble")
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

#Preview {
    NavigationStack {
        IssueDetailView(issueId: UUID())
            .environmentObject(AppStore())
    }
}
