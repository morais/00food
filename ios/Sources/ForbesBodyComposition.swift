import Foundation

// Forbes partitions sustained weight loss between fat and fat-free mass:
// dFM/dWeight = FM / (FM + 10.4 kg). No water/glycogen change is inferred.
// https://doi.org/10.1017/S0007114507691946
struct ForbesBodyComposition: Equatable {
    let weightKg: Double
    let fatMassKg: Double
    var fatFreeMassKg: Double { weightKg - fatMassKg }
    var bodyFatPercentage: Double { fatMassKg / weightKg * 100 }
    var fatFraction: Double { fatMassKg / (fatMassKg + 10.4) }

    init?(weightKg: Double, bodyFatPercentage: Double) {
        guard weightKg.isFinite, weightKg > 0, bodyFatPercentage.isFinite,
              bodyFatPercentage > 0, bodyFatPercentage < 100 else { return nil }
        self.weightKg = weightKg
        fatMassKg = weightKg * bodyFatPercentage / 100
    }

    private init(weightKg: Double, fatMassKg: Double) {
        self.weightKg = weightKg
        self.fatMassKg = fatMassKg
    }

    func losing(sustainedWeightKg loss: Double) -> ForbesBodyComposition? {
        guard loss.isFinite, loss >= 0, loss < weightKg else { return nil }
        var remaining = loss
        var weight = weightKg
        var fat = fatMassKg
        // Small mass steps recalculate the fraction as fat mass falls. RK4
        // integrates the same Forbes fraction without a step-size bias.
        func fraction(_ mass: Double) -> Double { max(0, mass) / (max(0, mass) + 10.4) }
        while remaining > 1e-10 {
            let step = min(0.05, remaining)
            let k1 = fraction(fat)
            let k2 = fraction(fat - step * k1 / 2)
            let k3 = fraction(fat - step * k2 / 2)
            let k4 = fraction(fat - step * k3)
            fat = max(0, fat - step * (k1 + 2 * k2 + 2 * k3 + k4) / 6)
            weight -= step
            guard fat <= weight else { return nil }
            remaining -= step
        }
        return ForbesBodyComposition(weightKg: weightKg - loss, fatMassKg: fat)
    }
}

struct BodyCompositionBaseline {
    let date: Date
    let composition: ForbesBodyComposition
    let fatReadingDays: Int
    let weightReadingDays: Int

    static func make(bodyFat: [HealthMeasurePoint], weight: [HealthMeasurePoint],
                     latestBodyFat: HealthMeasurePoint?, latestWeight: HealthMeasurePoint?,
                     fallbackWeightKg: Double, now: Date = Date(),
                     calendar: Calendar = .current) -> BodyCompositionBaseline? {
        let fatReadings = (bodyFat + [latestBodyFat].compactMap { $0 }).filter {
            $0.date <= now && $0.value.isFinite && $0.value > 0 && $0.value < 100
        }
        guard let lastFat = fatReadings.max(by: { $0.date < $1.date }) else { return nil }
        let fatWindow = window(fatReadings, ending: lastFat.date, calendar: calendar)
        guard let percentage = median(fatWindow.map(\.value)) else { return nil }
        let weightReadings = (weight + [latestWeight].compactMap { $0 }).filter {
            $0.date <= now && $0.value.isFinite && (25...400).contains($0.value)
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastFat.date)) ?? lastFat.date
        let availableWeights = weightReadings.filter { $0.date < nextDay }
        let weightWindow = window(availableWeights, ending: lastFat.date, calendar: calendar)
        let kg = median(weightWindow.map(\.value))
            ?? availableWeights.max(by: { $0.date < $1.date })?.value ?? fallbackWeightKg
        guard let composition = ForbesBodyComposition(weightKg: kg, bodyFatPercentage: percentage) else { return nil }
        return BodyCompositionBaseline(date: lastFat.date, composition: composition,
                                       fatReadingDays: fatWindow.count, weightReadingDays: weightWindow.count)
    }

    static func smoothedWeight(_ readings: [HealthMeasurePoint], latest: HealthMeasurePoint?,
                               now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let valid = (readings + [latest].compactMap { $0 }).filter {
            $0.date <= now && $0.value.isFinite && (25...400).contains($0.value)
        }
        return median(window(valid, ending: now, calendar: calendar).map(\.value))
            ?? valid.max(by: { $0.date < $1.date })?.value
    }

    private static func window(_ readings: [HealthMeasurePoint], ending date: Date,
                               calendar: Calendar) -> [HealthMeasurePoint] {
        let day = calendar.startOfDay(for: date)
        let first = calendar.date(byAdding: .day, value: -6, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? date
        return HealthHistory.lastReadingEachDay(readings.filter { $0.date >= first && $0.date < end },
                                               calendar: calendar)
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
