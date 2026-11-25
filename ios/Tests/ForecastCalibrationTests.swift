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
        let data = try XCTUnwrap(result.diagnostics)
        XCTAssertEqual(data.recordedDeficitKcal, 400, accuracy: 0.001)
        XCTAssertEqual(data.meanLoggedKcal, 2100, accuracy: 0.001)
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

    func testShorterHistoryReceivesLessWeight() throws {
        let shorter = try XCTUnwrap(calibration(history(days: 28)))
        let longer = try XCTUnwrap(calibration(history()))
        XCTAssertLessThan(abs(shorter.correctionKcal), abs(longer.correctionKcal))
    }

    func testMismatchesOverOneThousandAreRejectedBeforeWeighting() throws {
        for observed in [-3000.0, 3000, -500.01, 1500.01] {
            let input = history(observedGap: observed)
            XCTAssertNil(calibration(input))
            let assessment = try XCTUnwrap(ForecastCalibration.assess(weights: input.weights,
                resting: input.resting, active: input.active, logs: input.logs,
                since: input.start, now: now, calendar: calendar))
            XCTAssertNil(assessment.calibration)
            XCTAssertTrue(assessment.diagnostics.isRejected)
            XCTAssertGreaterThan(abs(assessment.diagnostics.rawCorrectionKcal), 1000)
            XCTAssertEqual(assessment.energyDays, 42)
        }
    }

    func testValidBoundaryMismatchIsNotCappedAndWeightingRemainsUnchanged() throws {
        for observed in [-500.0, 1500] {
            let result = try XCTUnwrap(calibration(history(observedGap: observed)))
            let data = try XCTUnwrap(result.diagnostics)
            XCTAssertFalse(data.isRejected)
            XCTAssertEqual(abs(data.rawCorrectionKcal), 1000, accuracy: 0.000001)
            XCTAssertEqual(result.correctionKcal, data.rawCorrectionKcal * data.influence, accuracy: 0.000001)
        }
    }

    func testDisplayedAdjustmentFactorsReproduceAppliedWeight() throws {
        let result = try XCTUnwrap(calibration(history()))
        let data = try XCTUnwrap(result.diagnostics)
        let factors = try XCTUnwrap(data.weighting)
        XCTAssertEqual(factors.weeks, 6)
        XCTAssertEqual(factors.historyFactor, 4.0 / 6, accuracy: 0.000001)
        XCTAssertEqual(factors.energyCoverage, 1)
        XCTAssertEqual(factors.weightCoverage, 1)
        XCTAssertEqual(factors.consistency, 1, accuracy: 0.000001)
        XCTAssertEqual(data.influence, factors.historyFactor * factors.energyCoverage * factors.weightCoverage * factors.consistency)
        XCTAssertEqual(result.correctionKcal, data.rawCorrectionKcal * factors.fraction)
    }

    func testCalibrationAllowanceBalanceUsesItsOwnFitPeriodAndCurrentPlan() throws {
        let data = try XCTUnwrap(calibration(history())?.diagnostics)
        let balance = data.allowanceBalance(deficitPercent: 15)
        XCTAssertEqual(balance.allowanceKcal, 2125, accuracy: 0.000001)
        XCTAssertEqual(balance.remainingKcal, 125, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(balance.remainingPercent), 125.0 / 2125 * 100, accuracy: 0.000001)
        let over = data.allowanceBalance(deficitPercent: 30)
        XCTAssertEqual(over.remainingKcal, -250, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(over.remainingPercent), -250.0 / 1750 * 100, accuracy: 0.000001)
        XCTAssertNil(data.allowanceBalance(deficitPercent: 100).remainingPercent)
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

    func testDisplayedDeficitPercentageKeepsFoodAllowanceFixed() throws {
        let budget = CalorieBudget(tdeeKcal: 2500, deficitPercent: 20)
        let slower = ForecastCalibration(correctionKcal: -149, windowDays: 42, energyDays: 42, weightDays: 42, weightWeeks: 6)
        let faster = ForecastCalibration(correctionKcal: 149, windowDays: 42, energyDays: 42, weightDays: 42, weightWeeks: 6)
        XCTAssertEqual(try XCTUnwrap(slower.projectionDeficitPercent(for: budget)), 351.0 / 2351 * 100, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(faster.projectionDeficitPercent(for: budget)), 649.0 / 2649 * 100, accuracy: 0.00001)
        XCTAssertEqual(budget.allowanceKcal, 2000)
        XCTAssertEqual(budget.deficitPercent, 20)
        XCTAssertTrue(slower.adjustmentDescription.contains("less deficit — slower loss"))
        XCTAssertTrue(faster.adjustmentDescription.contains("more deficit — faster loss"))
    }

    func testDisplayedPercentageHandlesUnchangedAndFlatProjections() throws {
        let budget = CalorieBudget(tdeeKcal: 2500, deficitPercent: 20)
        let unchanged = ForecastCalibration(correctionKcal: 0, windowDays: 42, energyDays: 42, weightDays: 42, weightWeeks: 6)
        let flat = ForecastCalibration(correctionKcal: -600, windowDays: 42, energyDays: 42, weightDays: 42, weightWeeks: 6)
        XCTAssertEqual(unchanged.projectionDeficitPercent(for: budget), 20)
        XCTAssertEqual(flat.projectionDeficitPercent(for: budget), 0)
        XCTAssertNil(unchanged.projectionDeficitPercent(for: CalorieBudget(tdeeKcal: 0, deficitPercent: 0)))
        XCTAssertEqual(unchanged.adjustmentDescription, "Forecast adjustment: unchanged.")
    }

    func testDiagnosticsCompareRecordedFoodAndWeightOverTheFitPeriodBeforeDamping() throws {
        let result = try XCTUnwrap(calibration(history()))
        let data = try XCTUnwrap(result.diagnostics)
        XCTAssertEqual(data.meanTDEEKcal, 2500, accuracy: 0.001)
        XCTAssertEqual(data.meanLoggedKcal, 2000, accuracy: 0.001)
        XCTAssertEqual(data.recordedDeficitKcal, 500, accuracy: 0.001)
        XCTAssertEqual(data.weightEquivalentDeficitKcal, 250, accuracy: 0.001)
        XCTAssertEqual(data.recordedDeficitPercent, 20, accuracy: 0.001)
        XCTAssertEqual(data.weightEquivalentDeficitPercent, 10, accuracy: 0.001)
        XCTAssertEqual(data.mismatchPercentagePoints, -10, accuracy: 0.001)
        XCTAssertEqual(data.rawCorrectionKcal, -250, accuracy: 0.001)
        XCTAssertEqual(result.correctionKcal, data.rawCorrectionKcal * data.influence, accuracy: 0.001)
        XCTAssertEqual(calendar.dateComponents([.day], from: data.fitStart, to: data.fitEnd).day, 35)
        XCTAssertGreaterThan(data.fitStart, data.inputStart)
        XCTAssertLessThan(data.fitEnd, data.inputEnd)
    }

    func testDiagnosticsUseActualIntakeAndKeepValidRawMismatchUncapped() throws {
        var input = history(observedGap: 100)
        for index in input.logs.indices { input.logs[index].kcal = 1500 }
        let result = try XCTUnwrap(calibration(input))
        let data = try XCTUnwrap(result.diagnostics)
        XCTAssertEqual(data.recordedDeficitKcal, 1000, accuracy: 0.001)
        XCTAssertEqual(data.recordedDeficitPercent, 40, accuracy: 0.001)
        XCTAssertEqual(data.weightEquivalentDeficitKcal, 100, accuracy: 0.001)
        XCTAssertEqual(data.rawCorrectionKcal, -900, accuracy: 0.001)
        XCTAssertEqual(result.correctionKcal, -600, accuracy: 0.001)
    }
}
