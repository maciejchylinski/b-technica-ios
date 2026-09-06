import SwiftUI

/// Prompts for the real-world distance between the two calibration points and
/// its unit (mm / cm / m).
struct DistanceInputSheet: View {
    /// Called with the entered value and unit when the user taps Save.
    var onSave: (Double, LengthUnit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var unit: LengthUnit = .cm

    private var parsedValue: Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Real distance between A and B") {
                    HStack {
                        TextField("e.g. 100", text: $text)
                            .keyboardType(.decimalPad)
                            .font(.title3)
                        Picker("Unit", selection: $unit) {
                            ForEach(LengthUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }

                Section {
                    Text("Enter how far apart the two points you tapped are in the real world. This sets the drawing scale.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let value = parsedValue {
                            onSave(value, unit)
                        }
                    }
                    .disabled(parsedValue == nil)
                }
            }
        }
    }
}

#Preview {
    Text("Host").sheet(isPresented: .constant(true)) {
        DistanceInputSheet { _, _ in }
    }
}
