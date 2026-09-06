import SwiftUI

/// "More" tab: project info, app details, and secondary placeholders.
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

                Section("Tools") {
                    NavigationLink {
                        EquipmentView()
                    } label: {
                        Label("Equipment", systemImage: "shippingbox")
                    }
                }

                Section("App") {
                    LabeledContent("Name", value: "BTechnica")
                    LabeledContent("Mode", value: "Offline · local storage")
                }

                Section {
                    Text("BTechnica is an offline-first construction field app. Import a PDF drawing, pin issues, and attach photos.")
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
