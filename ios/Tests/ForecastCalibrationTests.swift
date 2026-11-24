import XCTest
@testable import ZeroZeroFood

final class ForecastCalibrationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12))! }

    private struct History {
        var start: Date
        var weights: [HealthMeasurePoint]
        var resting: [HealthMeasurePoint]
        var active: [HealthMeasurePoint]
        var logs: [FoodLog]
    }

    private func history(days: Int = 42, observedGap: Double = 250, variableGap: Bool = false) -> History {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        var result = History(start: start, weights: [], resting: [], active: [], logs: [])
        var kg = 85.0
        for day in 0..<days {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            let gap = variableGap ? Double(200 + day * 10) : 500
            result.weights.append(HealthMeasurePoint(date: date, value: kg))
            result.resting.append(HealthMeasurePoint(date: date, value: 1800))
            result.active.append(HealthMeasurePoint(date: date, value: 700))
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            result.logs.append(FoodLog(id: "log-\(day)", foodId: "food", foodName: "Daily food", serving: "Day",
                quantity: 1, kcal: 2500 - Int(gap), localDate: key,
                loggedAt: ISO8601DateFormatter().string(from: date)))
            kg -= (variableGap ? gap : observedGap) / 7700
        }
        return result
    }

    private func calibration(_ history: History) -> ForecastCalibration? {
        ForecastCalibration.make(weights: history.weights, resting: history.resting, active: history.active,
                                 logs: history.logs, since: history.start, now: now, calendar: calendar)
    }

    func testSlowerObservedLossDampsForecastCorrectionAndLeavesBudgetInputsAlone() throws {
        let history = history()
        let result = try XCTUnwrap(calibration(history))
        XCTAssertEqual(result.windowDays, 42)
        XCTAssertEqual(result.energyDays, 42)
        XCTAssertEqual(result.correctionKcal, -250 * (4.0 / 6), accuracy: 0.001)
        let budget = CalorieBudget(tdeeKcal: 2500, deficitPercent: 20)
        XCTAssertEqual(result.projectionGap(budget.gapKcal), 333)
        XCTAssertEqual(budget.allowanceKcal, 2000)
        XCTAssertEqual(budget.tdeeKcal, 2500)
        XCTAssertEqual(budget.deficitPercent, 20)
    }

    func testAgreementWithRecordedEnergyKeepsStandardForecastEvenWhenDailyIntakeVaries() throws {
        let result = try XCTUnwrap(calibration(history(variableGap: true)))
        XCTAssertEqual(result.correctionKcal, 0, accuracy: 0.001)
        XCTAssertEqual(result.projectionGap(500), 500)
    }

    func testInsufficientMissingOrStaleHistoryFallsBack() {
        XCTAssertNil(calibration(history(days: 27)))
        var missingFood = history()
        missingFood.logs.removeLast(5)
        XCTAssertNil(calibration(missingFood))
        var missingHealth = history()
        missingHealth.active.removeLast(5)
        XCTAssertNil(calibration(missingHealth))
        var sparseWeights = history()
        sparseWeights.weights = Array(sparseWeights.weights.prefix(13))
        XCTAssertNil(calibration(sparseWeights))
        var staleWeights = history()
        staleWeights.weights.removeLast(8)
        XCTAssertNil(calibration(staleWeights))
    }

    func testIndividualScaleSpikeAndMultipleReadingsDoNotDominateTrend() throws {
        var history = history()
        let original = try XCTUnwrap(calibration(history))
        let date = history.weights[17].date
        history.weights.append(HealthMeasurePoint(date: date.addingTimeInterval(60), value: 100))
        let result = try XCTUnwrap(calibration(history))
        XCTAssertEqual(result.weightDays, 42)
        XCTAssertEqual(result.correctionKcal, original.correctionKcal, accuracy: 2)
    }

    func testTodayAndPreAccountHistoryAreExcludedAndSmallGapsDoNotBecomeGainForecasts() throws {
        var history = history()
        let original = try XCTUnwrap(calibration(history))
        history.weights.append(HealthMeasurePoint(date: now, value: 40))
        history.weights.append(HealthMeasurePoint(date: history.start.addingTimeInterval(-86400), value: 200))
        history.resting.append(HealthMeasurePoint(date: now, value: 9000))
        XCTAssertEqual(try XCTUnwrap(calibration(history)).correctionKcal, original.correctionKcal, accuracy: 0.001)
        XCTAssertEqual(original.projectionGap(100), 0)
        let budget = CalorieBudget(tdeeKcal: 2500, deficitPercent: 0)
        XCTAssertEqual(budget.allowanceKcal, 2500)
    }

    func testLimitsAndMinimumHistoryGiveLessInfluenceToShorterHistory() throws {
        let shorter = try XCTUnwrap(calibration(history(days: 28)))
        let longer = try XCTUnwrap(calibration(history()))
        XCTAssertLessThan(abs(shorter.correctionKcal), abs(longer.correctionKcal))
        let extreme = try XCTUnwrap(calibration(history(observedGap: 3000)))
        XCTAssertLessThanOrEqual(abs(extreme.correctionKcal), 300)
    }

    func testLargeInconsistentWeeklySwingsUseStandardForecast() {
        var history = history()
        history.weights = history.weights.enumerated().map { index, point in
            HealthMeasurePoint(date: point.date, value: point.value + ((index / 7).isMultiple(of: 2) ? 0 : 4))
        }
        XCTAssertNil(calibration(history))
    }

    func testCorrectedGapConsistentlyChangesWeightFatAndThresholdDates() throws {
        let result = try XCTUnwrap(calibration(history()))
        let end = calendar.date(byAdding: .month, value: 6, to: calendar.startOfDay(for: now))!
        let gap = result.projectionGap(500)
        let standard = ProgressProjection.projectedWeight(from: 80, gap: 500, minimum: 56, until: end, now: now, calendar: calendar)
        let calibrated = ProgressProjection.projectedWeight(from: 80, gap: gap, minimum: 56, until: end, now: now, calendar: calendar)
        XCTAssertGreaterThan(calibrated.last!.value, standard.last!.value)
        let standardBMI = try XCTUnwrap(ProgressProjection.estimatedBMIEntryDate(from: 80, gap: 500, upperBound: 76, until: end, now: now, calendar: calendar))
        let calibratedBMI = try XCTUnwrap(ProgressProjection.estimatedBMIEntryDate(from: 80, gap: gap, upperBound: 76, until: end, now: now, calendar: calendar))
        XCTAssertGreaterThan(calibratedBMI, standardBMI)
        let anchor = HealthMeasurePoint(date: calendar.startOfDay(for: now), value: 25)
        let standardFat = ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: 80, gapKcal: 500, minimumWeightKg: 56, until: end, calendar: calendar)
        let calibratedFat = ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: 80, gapKcal: gap, minimumWeightKg: 56, until: end, calendar: calendar)
        XCTAssertEqual(calibratedFat.first?.value, anchor.value)
        XCTAssertGreaterThan(calibratedFat.last!.value, standardFat.last!.value)
        let standardACE = try XCTUnwrap(ACEThresholdForecast.crossingDate(for: 23, in: standardFat))
        let calibratedACE = try XCTUnwrap(ACEThresholdForecast.crossingDate(for: 23, in: calibratedFat))
        XCTAssertGreaterThan(calibratedACE, standardACE)
    }
}
