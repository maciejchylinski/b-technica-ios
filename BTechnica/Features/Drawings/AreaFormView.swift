import SwiftUI
import UIKit

/// Name + color sheet used when finishing a new area or renaming an existing one.
struct AreaFormView: View {
    let title: String
    let confirmTitle: String
    @State private var name: String
    @State private var colorHex: String
    var onSave: (String, String) -> Void
    var onCancel: () -> Void

    init(
        title: String,
        confirmTitle: String = "Save",
        initialName: String = "",
        initialColor: String = Area.defaultColor,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        _name = State(initialValue: initialName)
        _colorHex = State(initialValue: initialColor)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Area name", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                        ForEach(Area.colorPresets, id: \.hex) { preset in
                            Button {
                                colorHex = preset.hex
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(uiColor: UIColor(hex: preset.hex) ?? .systemBlue))
                                        .frame(width: 36, height: 36)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(.white, lineWidth: colorHex == preset.hex ? 3 : 0)
                                        }
                                        .overlay {
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                        }
                                    Text(preset.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(colorHex == preset.hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Color")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onSave(name, colorHex)
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
