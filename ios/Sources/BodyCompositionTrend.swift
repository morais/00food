import Foundation

// Experimental personal trend, learned within the same completed-day window as the energy fit.
// Fat-free mass is not a direct muscle measurement or evidence of exercise causality.
struct BodyCompositionTrend: Sendable {
    // Hall's body-energy densities: 39.5 MJ/kg fat and 7.6 MJ/kg fat-free mass.
    // https://www.niddk.nih.gov/-/media/Files/BWP/Hall_Lancet_Web_Appendix.pdf
    static let fatKcalPerKg = 39_500_000.0 / 4184
    static let leanKcalPerKg = 7_600_000.0 / 4184

    struct Reading: Sendable {
        let date: Date
        let body: ForbesBodyComposition
    }
    let readings: [Reading]
    let window: DateInterval
    let firstDate: Date
    let lastDate: Date
    let weekCount: Int
    let fatChangeKgPerDay: Double
    let leanChangeKgPerDay: Double
    let confidence: Double
    let referenceFatMassKg: Double
    let leanLossPerFatLoss: Double

    static func make(weights: [HealthMeasurePoint], bodyFat: [HealthMeasurePoint],
                     since accountStart: Date, now: Date = Date(), calendar: Calendar = .current) -> Self? {
        guard let window = ForecastCalibration.historyWindow(since: accountStart, now: now, calendar: calendar) else { return nil }
        let completedWeeks = (calendar.dateComponents([.day], from: window.start, to: window.end).day ?? 0) / 7
        let weightDays = HealthHistory.lastReadingEachDay(weights.filter {
            $0.date >= window.start && $0.date < window.end && $0.value.isFinite && (25...400).contains($0.value)
        }, calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: weightDays.map { (calendar.startOfDay(for: $0.date), $0.value) })
        let fatDays = HealthHistory.lastReadingEachDay(bodyFat.filter {
            $0.date >= window.start && $0.date < window.end && $0.value.isFinite && $0.value > 0 && $0.value < 100
        }, calendar: calendar)
        let paired = fatDays.compactMap { point -> Reading? in
            guard let weight = byDay[calendar.startOfDay(for: point.date)],
                  let body = ForbesBodyComposition(weightKg: weight, bodyFatPercentage: point.value) else { return nil }
            return Reading(date: point.date, body: body)
        }
        guard paired.count >= 14, let first = paired.first, let last = paired.last,
              (calendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0) >= 28,
              (calendar.dateComponents([.day], from: last.date, to: now).day ?? 99) <= 7 else { return nil }
        let anchor = window.end
        let groups = Dictionary(grouping: paired) { reading in
            ((calendar.dateComponents([.day], from: calendar.startOfDay(for: reading.date), to: anchor).day ?? 0) - 1) / 7
        }
        struct Week { let x: Double; let weight: Double; let fat: Double; let importance: Double }
        let origin = calendar.startOfDay(for: first.date)
        var weeks: [Week] = []
        for (index, group) in groups where index < completedWeeks && group.count >= 2 {
            let x = median(group.map { Double(calendar.dateComponents([.day], from: origin, to: calendar.startOfDay(for: $0.date)).day ?? 0) })
            let age = Double(calendar.dateComponents([.day], from: origin, to: anchor).day ?? 0) - x
            weeks.append(Week(x: x, weight: median(group.map { $0.body.weightKg }),
                              fat: median(group.map { $0.body.fatMassKg }),
                              importance: max(1e-12, pow(0.5, age / 90))))
        }
        weeks.sort { $0.x < $1.x }
        guard weeks.count >= 4, let beginning = weeks.first, let ending = weeks.last,
              ending.x - beginning.x >= 21 else { return nil }
        var fatSlopes: [(Double, Double)] = []
        var weightSlopes: [(Double, Double)] = []
        for left in weeks.indices {
            for right in weeks.indices where right > left {
                let distance = weeks[right].x - weeks[left].x
                guard distance >= 14 else { continue }
                let importance = weeks[left].importance * weeks[right].importance
                fatSlopes.append(((weeks[right].fat - weeks[left].fat) / distance, importance))
                weightSlopes.append(((weeks[right].weight - weeks[left].weight) / distance, importance))
            }
        }
        guard !fatSlopes.isEmpty else { return nil }
        let fatSlope = weightedMedian(fatSlopes)
        let weightSlope = weightedMedian(weightSlopes)
        let leanSlope = weightSlope - fatSlope
        // No personal loss partition can be inferred from a flat/rising fat trend.
        guard fatSlope < -0.0001 else { return nil }
        let fatIntercept = weightedMedian(weeks.map { ($0.fat - fatSlope * $0.x, $0.importance) })
        let leanIntercept = weightedMedian(weeks.map { ($0.weight - $0.fat - leanSlope * $0.x, $0.importance) })
        let fatScatter = weightedMedian(weeks.map { (abs($0.fat - fatIntercept - fatSlope * $0.x), $0.importance) })
        let leanScatter = weightedMedian(weeks.map { (abs($0.weight - $0.fat - leanIntercept - leanSlope * $0.x), $0.importance) })
        let noiseLimit = max(0.75, median(paired.map { $0.body.weightKg }) * 0.015)
        guard max(fatScatter, leanScatter) < noiseLimit else { return nil }
        let effectiveDays = paired.reduce(0.0) { total, reading in
            let age = Double(calendar.dateComponents([.day], from: reading.date, to: now).day ?? 0)
            return total + pow(0.5, max(0, age) / 90)
        }
        let confidence = min(1, (ending.x - beginning.x) / 56) * min(1, effectiveDays / 28)
            * max(0, 1 - max(fatScatter, leanScatter) / noiseLimit)
        guard confidence > 0 else { return nil }
        return Self(readings: paired, window: window, firstDate: first.date, lastDate: last.date, weekCount: weeks.count,
                    fatChangeKgPerDay: fatSlope, leanChangeKgPerDay: leanSlope, confidence: confidence,
                    referenceFatMassKg: ending.fat, leanLossPerFatLoss: min(3, max(-1, leanSlope / fatSlope)))
    }

    // Weekly aggregation uses the same completed-day buckets as the energy fit.
    func aggregate(from start: Date, to end: Date, calendar: Calendar = .current) -> Reading? {
        let points = readings.filter { $0.date >= start && $0.date < end }
        guard points.count >= 2,
              let body = ForbesBodyComposition(weightKg: Self.median(points.map { $0.body.weightKg }),
                                               fatMassKg: Self.median(points.map { $0.body.fatMassKg })) else { return nil }
        let days = points.map { Double(calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: $0.date)).day ?? 0) }
        let day = Self.median(days)
        let date = calendar.date(byAdding: .day, value: Int(day), to: start)!
        let next = calendar.date(byAdding: .day, value: 1, to: date)!
        return Reading(date: date.addingTimeInterval(next.timeIntervalSince(date) * (day - floor(day))), body: body)
    }

    func energyEquivalentKg(_ body: ForbesBodyComposition) -> Double {
        let measured = (body.fatMassKg * Self.fatKcalPerKg + body.fatFreeMassKg * Self.leanKcalPerKg) / 7700
        return body.weightKg * (1 - confidence) + measured * confidence
    }

    func advance(_ body: ForbesBodyComposition, deficitKcal: Double) -> ForbesBodyComposition? {
        guard deficitKcal.isFinite, deficitKcal >= 0 else { return nil }
        var current = body
        var remaining = deficitKcal
        while remaining > 1e-8 {
            let energy = min(100, remaining)
            // Gradually return to Forbes outside the observed fat-mass range;
            // never promise indefinite lean preservation at very low fat mass.
            let strength = confidence * min(1, current.fatMassKg / referenceFatMassKg)
            let forbesRatio = 10.4 / max(current.fatMassKg, 1e-8)
            let leanPerFat = max(-1, forbesRatio * (1 - strength) + leanLossPerFatLoss * strength)
            let fatLoss = energy / (Self.fatKcalPerKg + Self.leanKcalPerKg * leanPerFat)
            let leanLoss = fatLoss * leanPerFat
            guard let next = ForbesBodyComposition(weightKg: current.weightKg - fatLoss - leanLoss,
                                                   fatMassKg: current.fatMassKg - fatLoss) else { return nil }
            current = next
            remaining -= energy
        }
        return current
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func weightedMedian(_ values: [(Double, Double)]) -> Double {
        let sorted = values.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(0.0) { $0 + $1.1 } / 2
        var cumulative = 0.0
        for value in sorted {
            cumulative += value.1
            if cumulative >= half { return value.0 }
        }
        return sorted.last!.0
    }
}

struct BodyCompositionForecastPoint {
    let date: Date
    let body: ForbesBodyComposition
}

extension BodyCompositionTrend {
    static func entryDate(in points: [BodyCompositionForecastPoint], upperWeight: Double) -> Date? {
        guard points.count > 1, let first = points.first, first.body.weightKg > upperWeight else { return nil }
        for index in 1..<points.count {
            let before = points[index - 1]
            let after = points[index]
            if before.body.weightKg > upperWeight, after.body.weightKg <= upperWeight {
                let fraction = (before.body.weightKg - upperWeight) / (before.body.weightKg - after.body.weightKg)
                return before.date.addingTimeInterval(after.date.timeIntervalSince(before.date) * fraction)
            }
        }
        return nil
    }

    func projection(from body: ForbesBodyComposition, startingAt start: Date, until end: Date,
                    gapKcal: Int, minimumWeightKg: Double, calendar: Calendar = .current) -> [BodyCompositionForecastPoint] {
        guard start <= end, body.weightKg >= minimumWeightKg else { return [] }
        var result = [BodyCompositionForecastPoint(date: start, body: body)]
        var date = start
        var current = body
        while date < end {
            let next = min(end, calendar.date(byAdding: .day, value: 1, to: date) ?? end)
            guard next > date,
                  let body = advance(current, deficitKcal: Double(max(0, gapKcal)) * next.timeIntervalSince(date) / 86400),
                  body.weightKg >= minimumWeightKg else { break }
            result.append(BodyCompositionForecastPoint(date: next, body: body))
            current = body
            date = next
        }
        return result
    }
}
