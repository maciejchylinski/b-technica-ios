import SwiftUI

/// Pick a bundled sample floor plan to import into the project.
struct SampleDrawingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPick: (SampleDrawing) -> Void

    var body: some View {
        NavigationStack {
            List(SampleDrawing.allCases) { sample in
                Button {
                    onPick(sample)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.defaultName)
                            .foregroundStyle(.primary)
                        Text(sample.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Sample drawings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SampleDrawingsSheet { _ in }
}
