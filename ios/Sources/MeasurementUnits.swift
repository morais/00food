import Foundation

enum FoodUnitSystem: String, Codable, CaseIterable {
    case metric, us, uk
    // Exact SI definitions avoid the rounded coefficients in UnitMass/Volume.
    private static let kilogramsPerPound = 0.45359237
    private var millilitersPerOunce: Double { self == .us ? 29.5735295625 : 28.4130625 }
    var usesFeet: Bool { self != .metric }
    var weightSymbol: String { usesFeet ? "lb" : "kg" }
    var waterSymbol: String { usesFeet ? "fl oz" : "mL" }
    var weightName: String { usesFeet ? "pounds" : "kilograms" }
    var waterName: String { self == .us ? "US fluid ounces" : self == .uk ? "imperial fluid ounces" : "milliliters" }

    func weightValue(_ kg: Double) -> Double {
        usesFeet ? kg / Self.kilogramsPerPound : kg
    }
    func kilograms(_ value: Double) -> Double {
        usesFeet ? value * Self.kilogramsPerPound : value
    }
    func inches(_ cm: Double) -> Double {
        cm / 2.54
    }
    func centimeters(feet: Double, inches: Double) -> Double {
        (feet * 12 + inches) * 2.54
    }
    func heightParts(_ cm: Double) -> (feet: Double, inches: Double) {
        let total = (inches(cm) * 10).rounded() / 10
        let feet = floor(total / 12)
        return (feet, total - feet * 12)
    }
    func waterValue(_ ml: Double) -> Double {
        guard self != .metric else { return ml }
        return ml / millilitersPerOunce
    }
    func milliliters(_ value: Double) -> Double {
        guard self != .metric else { return value }
        return value * millilitersPerOunce
    }
    func weight(_ kg: Double) -> String {
        "\(weightValue(kg).formatted(.number.precision(.fractionLength(1)))) \(weightSymbol)"
    }
    func spokenWeight(_ kg: Double) -> String {
        "\(weightValue(kg).formatted(.number.precision(.fractionLength(1)))) \(weightName)"
    }
    func weightRange(_ range: ClosedRange<Double>) -> String {
        "\(weightValue(range.lowerBound).formatted(.number.precision(.fractionLength(1))))–\(weightValue(range.upperBound).formatted(.number.precision(.fractionLength(1)))) \(weightSymbol)"
    }
    func water(_ ml: Double) -> String {
        "\(waterValue(ml).formatted(.number.precision(.fractionLength(self == .metric ? 0 : 1)))) \(waterSymbol)"
    }
    func spokenWater(_ ml: Double) -> String {
        "\(waterValue(ml).formatted(.number.precision(.fractionLength(self == .metric ? 0 : 1)))) \(waterName)"
    }
    var weightTickStep: Double { usesFeet ? 10 : 5 }
    var weightEnergyExplanation: String {
        usesFeet ? "about 3,500 kcal per lb" : "about 7,700 kcal per kg"
    }
    var forbesConstant: String { usesFeet ? "22.9 lb" : "10.4 kg" }
}

enum MeasurementPreference: String, CaseIterable {
    case system, metric, us, uk
    static let key = "measurementSystemOverride"
    var title: String {
        switch self {
        case .system: "Follow iPhone"
        case .metric: "Metric"
        case .us: "US"
        case .uk: "UK imperial"
        }
    }
    func resolved(measurementSystem: Locale.MeasurementSystem) -> FoodUnitSystem {
        switch self {
        case .metric: .metric
        case .us: .us
        case .uk: .uk
        case .system: measurementSystem == .us ? .us : measurementSystem == .uk ? .uk : .metric
        }
    }
    static func current(defaults: UserDefaults = .standard, locale: Locale = .autoupdatingCurrent) -> FoodUnitSystem {
        (MeasurementPreference(rawValue: defaults.string(forKey: key) ?? "") ?? .system)
            .resolved(measurementSystem: locale.measurementSystem)
    }
}
