import SwiftUI

/// "More" tab: project info and app details. Kept minimal for this slice.
struct MoreView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                Section("Project") {
                    LabeledContent("Name", value: store.data.project.name)
                    LabeledContent("Created",
                                   value: store.data.project.createdDate.formatted(date: .abbreviated,
                                                                                    time: .omitted))
                }

                Section("App") {
                    LabeledContent("Name", value: "BTechnica")
                    LabeledContent("Mode", value: "Offline · local storage")
                }

                Section {
                    Text("BTechnica is an offline-first construction field app. This build focuses on importing PDF drawings and calibrating their scale.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview {
    MoreView().environmentObject(AppStore())
}
