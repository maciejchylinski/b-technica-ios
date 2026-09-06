import SwiftUI

/// Simple project home. Shows the active project and a quick summary so the
/// app opens onto something concrete rather than an empty dashboard.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.data.project.name)
                            .font(.title2).bold()
                        Text("Active project")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Overview") {
                    summaryRow(icon: "doc.richtext",
                               title: "Drawings",
                               value: "\(store.data.drawings.count)")
                    summaryRow(icon: "checkmark.seal",
                               title: "Calibrated drawings",
                               value: "\(store.data.drawings.filter { $0.isCalibrated }.count)")
                    summaryRow(icon: "exclamationmark.bubble",
                               title: "Issues",
                               value: "\(store.data.issues.count)")
                }

                Section {
                    Text("Import a PDF drawing in the Drawings tab, open it, then set its scale to unlock measurements and pinned issues.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Home")
        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.blue)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HomeView().environmentObject(AppStore())
}
