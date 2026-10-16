import SwiftUI

/// Issues tab: lists every locally saved issue across drawings.
struct IssuesView: View {
    @EnvironmentObject private var store: AppStore

    private var sortedIssues: [Issue] {
        store.data.issues.sorted { lhs, rhs in
            if lhs.number != rhs.number { return lhs.number > rhs.number }
            return lhs.createdDate > rhs.createdDate
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedIssues.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Issues")
            .navigationDestination(for: Issue.self) { issue in
                IssueDetailView(issueId: issue.id)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(sortedIssues) { issue in
                NavigationLink(value: issue) {
                    IssueRow(issue: issue,
                             drawingName: drawingName(for: issue),
                             pageLabel: pageLabel(for: issue))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No issues yet", systemImage: "exclamationmark.bubble")
        } description: {
            Text("Open a drawing and tap Add issue to pin one on the PDF.")
        }
    }

    private func drawingName(for issue: Issue) -> String {
        store.data.drawings.first { $0.id == issue.drawingId }?.name ?? "Unknown drawing"
    }

    private func pageLabel(for issue: Issue) -> String? {
        store.data.drawings.first { $0.id == issue.drawingId }?.pageLabel(for: issue.pageIndex)
    }
}

/// One row in the Issues list.
private struct IssueRow: View {
    let issue: Issue
    let drawingName: String
    let pageLabel: String?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.blue)
                    .frame(width: 36, height: 36)
                Text("\(issue.number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(issue.status.label)
                    Text("·")
                    Text(drawingName)
                        .lineLimit(1)
                    if let pageLabel {
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
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    IssuesView().environmentObject(AppStore())
}
