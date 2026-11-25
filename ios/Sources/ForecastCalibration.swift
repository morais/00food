import Foundation

// Experimental forecast-only correction. Nothing here changes a FoodProfile,
// Health expenditure reading, CalorieBudget, food log, or stored daily allowance.
struct ForecastCalibration {
    static let preferenceKey = "developer.calibrateForecasts"
    let correctionKcal: Double
    let windowDays: Int
    let energyDays: Int
    let weightDays: Int
    let weightWeeks: Int
    var diagnostics: ForecastCalibrationDiagnostics? = nil

    func projectionGap(_ nominalGap: Int) -> Int {
        // Existing projections model sustained loss, not weight gain.
        max(0, Int((Double(nominalGap) + correctionKcal).rounded()))
    }

    func projectionDeficitPercent(for budget: CalorieBudget) -> Double? {
        let gap = Double(projectionGap(budget.gapKcal))
        // Express the curve as a percentage while keeping the actual food
        // allowance fixed. This is not a new expenditure or budget estimate.
        let impliedExpenditure = Double(budget.allowanceKcal) + gap
        guard impliedExpenditure > 0 else { return nil }
        return gap / impliedExpenditure * 100
    }

    var adjustmentDescription: String {
        let correction = Int(correctionKcal.rounded())
        guard correction != 0 else { return "Forecast adjustment: unchanged." }
        let direction = correction < 0 ? "less" : "more"
        let pace = correction < 0 ? "slower" : "faster"
        return "Forecast adjustment: \(abs(correction).formatted()) kcal/day \(direction) deficit — \(pace) loss."
    }

    static func make(weights: [HealthMeasurePoint], resting: [HealthMeasurePoint],
                     active: [HealthMeasurePoint], logs: [FoodLog], since accountStart: Date,
                     now: Date = Date(), calendar: Calendar = .current,
                     composition: BodyCompositionTrend? = nil) -> Self? {
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -42, to: today) else { return nil }
        let start = max(earliest, calendar.startOfDay(for: accountStart))
        let count = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        guard count >= 28 else { return nil }
        func offset(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? -1
        }
        func totals(_ points: [HealthMeasurePoint], valid: (Double) -> Bool) -> [Int: Double] {
            var days: [Int: Double] = [:]
            for point in HealthHistory.lastReadingEachDay(points, calendar: calendar) {
                let day = offset(point.date)
                if (0..<count).contains(day), valid(point.value) { days[day] = point.value }
            }
            return days
        }
        let restingByDay = totals(resting) { $0.isFinite && $0 > 0 }
        let activeByDay = totals(active) { $0.isFinite && $0 >= 0 }
        var foodByDay: [String: Double] = [:]
        for log in logs where log.kcal > 0 { foodByDay[log.localDate, default: 0] += Double(log.kcal) }
        var gaps: [Double?] = []
        var tdeeByDay: [Double?] = []
        var tdeeTotals: [Double] = []
        for day in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if let basal = restingByDay[day], let activity = activeByDay[day],
               let food = foodByDay[key] {
                gaps.append(basal + activity - food)
                tdeeByDay.append(basal + activity)
                tdeeTotals.append(basal + activity)
            } else { gaps.append(nil); tdeeByDay.append(nil) }
        }
        let coverage = Double(tdeeTotals.count) / Double(count)
        guard coverage >= 0.9 else { return nil }
        let recordedGaps = gaps.compactMap { $0 }
        let meanGap = recordedGaps.reduce(0, +) / Double(recordedGaps.count)
        let meanTDEE = tdeeTotals.reduce(0, +) / Double(tdeeTotals.count)
        // Fill the few missing days with the observed mean, never zero food.
        let dailyGaps = gaps.map { $0 ?? meanGap }
        var cumulativeGap = [0.0]
        for gap in dailyGaps { cumulativeGap.append(cumulativeGap.last! + gap) }
        func energyThrough(_ day: Double) -> Double {
            let whole = min(count - 1, max(0, Int(day)))
            return cumulativeGap[whole] + dailyGaps[whole] * (day - Double(whole))
        }

        let dailyWeights = HealthHistory.lastReadingEachDay(weights.filter {
            $0.value.isFinite && (25...400).contains($0.value) && $0.date >= start && $0.date < today
        }, calendar: calendar)
        guard dailyWeights.count >= 14, let latest = dailyWeights.last,
              offset(latest.date) >= count - 7 else { return nil }
        struct Week { let day: Double; let kg: Double }
        var weeks: [Week] = []
        for index in 0..<(count / 7) {
            let first = count - (index + 1) * 7
            let readings = dailyWeights.filter { (first..<(first + 7)).contains(offset($0.date)) }
            guard readings.count >= 2 else { continue }
            weeks.append(Week(day: median(readings.map { Double(offset($0.date)) }),
                              kg: median(readings.map(\.value))))
        }
        weeks.sort { $0.day < $1.day }
        // When paired fat readings support it, calibrate against changes in
        // tissue energy rather than treating every lost kg as 7,700 kcal.
        var usesComposition = false
        if let composition {
            var pairedWeeks: [Week] = []
            var pairedDays = 0
            for index in 0..<(count / 7) {
                let first = count - (index + 1) * 7
                let from = calendar.date(byAdding: .day, value: first, to: start)!
                let to = calendar.date(byAdding: .day, value: 7, to: from)!
                guard let reading = composition.aggregate(from: from, to: to, calendar: calendar) else { continue }
                let dayStart = calendar.startOfDay(for: reading.date)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let day = Double(offset(reading.date)) + reading.date.timeIntervalSince(dayStart) / nextDay.timeIntervalSince(dayStart)
                pairedWeeks.append(Week(day: day, kg: composition.energyEquivalentKg(reading.body)))
                pairedDays += composition.readings.filter { $0.date >= from && $0.date < to }.count
            }
            pairedWeeks.sort { $0.day < $1.day }
            if pairedDays >= 14, pairedWeeks.count >= 4, let first = pairedWeeks.first, let last = pairedWeeks.last,
               last.day - first.day >= 21, last.day >= Double(count - 7) {
                weeks = pairedWeeks
                usesComposition = true
            }
        }
        guard weeks.count >= 4, let first = weeks.first, let last = weeks.last,
              last.day - first.day >= 21 else { return nil }

        // Remove the change already explained by recorded energy balance. A
        // robust slope of the residual estimates a persistent forecast error,
        // even when food intake or exercise varies during the history window.
        let residuals = weeks.map { $0.kg + energyThrough($0.day) / 7700 }
        var slopes: [Double] = []
        for left in weeks.indices {
            for right in weeks.indices where right > left {
                let distance = weeks[right].day - weeks[left].day
                if distance >= 7 { slopes.append((residuals[right] - residuals[left]) / distance) }
            }
        }
        guard !slopes.isEmpty else { return nil }
        let slope = median(slopes)
        let intercept = median(weeks.indices.map { residuals[$0] - slope * weeks[$0].day })
        let scatter = median(weeks.indices.map { abs(residuals[$0] - (intercept + slope * weeks[$0].day)) })
        guard scatter <= 0.75 else { return nil }
        let limit = 1000.0
        let rawCorrection = min(limit, max(-limit, -slope * 7700))
        let confidence = min(0.75, Double(weeks.count - 2) / 6) * coverage
            * min(1, Double(dailyWeights.count) / 28) * max(0, 1 - scatter / 0.75)
        // Diagnostics use the exact span fitted between the weekly medians.
        // Do not mix a seven-day calorie average with a multiweek weight fit.
        var cumulativeTDEE = [0.0]
        let filledTDEE = tdeeByDay.map { $0 ?? meanTDEE }
        for total in filledTDEE { cumulativeTDEE.append(cumulativeTDEE.last! + total) }
        func tdeeThrough(_ day: Double) -> Double {
            let whole = min(count - 1, max(0, Int(day)))
            return cumulativeTDEE[whole] + filledTDEE[whole] * (day - Double(whole))
        }
        func dateAt(_ day: Double) -> Date {
            let whole = Int(day)
            let date = calendar.date(byAdding: .day, value: whole, to: start)!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            return date.addingTimeInterval(next.timeIntervalSince(date) * (day - Double(whole)))
        }
        let fitDays = last.day - first.day
        let fitGap = (energyThrough(last.day) - energyThrough(first.day)) / fitDays
        let fitTDEE = (tdeeThrough(last.day) - tdeeThrough(first.day)) / fitDays
        let diagnostics = ForecastCalibrationDiagnostics(inputStart: start, inputEnd: today,
            fitStart: dateAt(first.day), fitEnd: dateAt(last.day),
            meanTDEEKcal: fitTDEE, meanLoggedKcal: fitTDEE - fitGap,
            rawCorrectionKcal: -slope * 7700, limitedCorrectionKcal: rawCorrection,
            influence: confidence, usesBodyComposition: usesComposition)
        return Self(correctionKcal: rawCorrection * confidence, windowDays: count,
                    energyDays: tdeeTotals.count, weightDays: dailyWeights.count, weightWeeks: weeks.count,
                    diagnostics: diagnostics)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

struct ForecastCalibrationDiagnostics {
    let inputStart: Date
    let inputEnd: Date // Exclusive: today's incomplete data is not included.
    let fitStart: Date
    let fitEnd: Date
    let meanTDEEKcal: Double
    let meanLoggedKcal: Double
    let rawCorrectionKcal: Double
    let limitedCorrectionKcal: Double
    let influence: Double
    var usesBodyComposition: Bool = false

    var recordedDeficitKcal: Double { meanTDEEKcal - meanLoggedKcal }
    // Energy-equivalent of the fitted weight trajectory under the app's model,
    // before caps or damping; not a measurement of true expenditure or fat loss.
    var weightEquivalentDeficitKcal: Double { recordedDeficitKcal + rawCorrectionKcal }
    var recordedDeficitPercent: Double { recordedDeficitKcal / meanTDEEKcal * 100 }
    var weightEquivalentDeficitPercent: Double { weightEquivalentDeficitKcal / meanTDEEKcal * 100 }
    var mismatchPercentagePoints: Double { rawCorrectionKcal / meanTDEEKcal * 100 }
}
