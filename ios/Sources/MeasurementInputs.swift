import SwiftUI

private struct FoodUnitsKey: EnvironmentKey {
    static let defaultValue = MeasurementPreference.current()
}
extension EnvironmentValues {
    var foodUnits: FoodUnitSystem {
        get { self[FoodUnitsKey.self] }
        set { self[FoodUnitsKey.self] = newValue }
    }
}

// Optional canonical values keep missing onboarding fields empty. Formatting
// only affects display; an unchanged prefill retains its original precision.
struct HeightInput: View {
    @Binding var centimeters: Double?
    @Environment(\.foodUnits) private var units
    @State private var feetValue: Double?
    @State private var inchesValue: Double?
    private enum Field { case feet, inches }
    @FocusState private var focused: Field?
    var body: some View {
        HStack {
            if units.usesFeet {
                TextField("Feet", value: feet, format: .number.precision(.fractionLength(0)))
                    .focused($focused, equals: .feet)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Height in feet")
                Text("ft").foregroundStyle(.secondary)
                TextField("Inches", value: inches, format: .number.precision(.fractionLength(0...1)))
                    .focused($focused, equals: .inches)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Additional height in inches")
                Text("in").foregroundStyle(.secondary)
            } else {
                TextField("Height", value: $centimeters, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Height in centimeters")
                Text("cm").foregroundStyle(.secondary)
            }
        }
        .onAppear { loadParts() }
        .onChange(of: centimeters) { _, _ in if focused == nil { loadParts() } }
        .onChange(of: units) { _, _ in focused = nil; loadParts() }
    }
    private var feet: Binding<Double?> {
        Binding(get: { feetValue }, set: { feetValue = $0; saveParts() })
    }
    private var inches: Binding<Double?> {
        Binding(get: { inchesValue }, set: { inchesValue = $0; saveParts() })
    }
    private func loadParts() {
        guard let centimeters, centimeters.isFinite else { feetValue = nil; inchesValue = nil; return }
        let parts = units.heightParts(centimeters)
        feetValue = parts.feet
        inchesValue = parts.inches
    }
    private func saveParts() {
        guard let feetValue, feetValue.isFinite, feetValue.rounded() == feetValue,
              let inchesValue, inchesValue.isFinite, (0..<12).contains(inchesValue) else {
            centimeters = nil
            return
        }
        centimeters = units.centimeters(feet: feetValue, inches: inchesValue)
    }
}

struct WeightInput: View {
    @Binding var kilograms: Double?
    @Environment(\.foodUnits) private var units
    var body: some View {
        HStack {
            TextField("Weight", value: displayValue, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .accessibilityLabel("Weight in \(units.weightName)")
            Text(units.weightSymbol).foregroundStyle(.secondary)
        }
    }
    private var displayValue: Binding<Double?> {
        Binding(get: { kilograms.map(units.weightValue) }, set: { kilograms = $0.map(units.kilograms) })
    }
}
