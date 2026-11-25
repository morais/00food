import XCTest
@testable import ZeroZeroFood

final class BodyCompositionTrendTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))! }
    private struct History {
        var weights: [HealthMeasurePoint] = []
        var fat: [HealthMeasurePoint] = []
    }

    private func history(days: Int = 140, fatLoss: Double = 0.04, leanGain: Double = 0) -> History {
        var result = History()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        for day in 0..<days {
            let date = calendar.date(byAdding: .hour, value: 9,
                to: calendar.date(byAdding: .day, value: day, to: start)!)!
            let fm = 30 - Double(day) * fatLoss
            let ffm = 60 + Double(day) * leanGain
            result.weights.append(.init(date: date, value: fm + ffm))
            result.fat.append(.init(date: date, value: fm / (fm + ffm) * 100))
        }
        return result
    }

    private func trend(_ input: History, since start: Date? = nil) -> BodyCompositionTrend? {
        BodyCompositionTrend.make(weights: input.weights, bodyFat: input.fat,
                                  since: start ?? input.weights.first?.date ?? now, now: now, calendar: calendar)
    }

    func testSharedRecentWindowLearnsLeanPreservation() throws {
        let input = history()
        let model = try XCTUnwrap(trend(input))
        XCTAssertEqual(model.readings.count, 42)
        XCTAssertEqual(model.firstDate, input.fat.suffix(42).first?.date)
        XCTAssertEqual(model.fatChangeKgPerDay, -0.04, accuracy: 0.000001)
        XCTAssertEqual(model.leanChangeKgPerDay, 0, accuracy: 0.000001)
        XCTAssertEqual(model.weekCount, 6)
        XCTAssertEqual(model.confidence, 1, accuracy: 0.000001)
        XCTAssertNil(trend(History(weights: Array(input.weights.suffix(7)), fat: Array(input.fat.suffix(7)))))
        let body = try XCTUnwrap(model.readings.last?.body)
        let personalized = try XCTUnwrap(model.advance(body, deficitKcal: 15_000))
        let standard = try XCTUnwrap(body.losing(sustainedWeightKg: 15_000 / 7700))
        XCTAssertGreaterThan(personalized.fatFreeMassKg, standard.fatFreeMassKg)
        XCTAssertLessThan(personalized.fatMassKg, standard.fatMassKg)
        XCTAssertGreaterThan(personalized.weightKg, standard.weightKg,
                             "Mostly-fat loss can be slower on the scale at the same energy deficit")
        XCTAssertEqual((body.fatMassKg - personalized.fatMassKg) * BodyCompositionTrend.fatKcalPerKg
                       + (body.fatFreeMassKg - personalized.fatFreeMassKg) * BodyCompositionTrend.leanKcalPerKg,
                       15_000, accuracy: 0.001)
    }

    func testStableScaleCanHaveFallingFatAndIncreasingFatFreeMass() throws {
        let model = try XCTUnwrap(trend(history(leanGain: 0.04)))
        XCTAssertEqual(model.fatChangeKgPerDay, -0.04, accuracy: 0.000001)
        XCTAssertEqual(model.leanChangeKgPerDay, 0.04, accuracy: 0.000001)
        let body = try XCTUnwrap(model.readings.last?.body)
        let after = try XCTUnwrap(model.advance(body, deficitKcal: 15_000))
        XCTAssertLessThan(after.bodyFatPercentage, body.bodyFatPercentage)
        XCTAssertGreaterThan(after.fatFreeMassKg, body.fatFreeMassKg)
        XCTAssertLessThan(body.weightKg - after.weightKg, 15_000 / 7700)
    }

    func testRecentSpikeDoesNotReplaceTheSixWeekTrendAndDuplicateDaysCountOnce() throws {
        var input = history()
        for index in (input.fat.count - 7)..<input.fat.count { input.fat[index] = .init(date: input.fat[index].date, value: input.fat[index].value + 2) }
        let date = input.fat[input.fat.count - 20].date.addingTimeInterval(-60)
        input.fat.append(.init(date: date, value: 99))
        input.fat.append(.init(date: now.addingTimeInterval(86400), value: 1))
        let model = try XCTUnwrap(trend(input))
        XCTAssertEqual(model.readings.count, 42)
        XCTAssertEqual(model.fatChangeKgPerDay, -0.04, accuracy: 0.005)
    }

    func testMissingSparseStaleOrNoisyFatHistoryFallsBack() {
        let full = history()
        XCTAssertNil(trend(History(weights: full.weights)))
        XCTAssertNil(trend(History(fat: full.fat)))
        XCTAssertNil(trend(History(weights: full.weights, fat: Array(full.fat.suffix(13)))))
        XCTAssertNil(trend(History(weights: full.weights, fat: Array(full.fat.dropLast(10)))))
        var noisy = history()
        let noise = [4.0, -2, 1, -4, 3, 0, -3, 2, -1]
        for index in noisy.fat.indices {
            let kg = noisy.weights[index].value
            let fatMass = kg * noisy.fat[index].value / 100 + noise[(index / 7) % noise.count]
            noisy.fat[index] = .init(date: noisy.fat[index].date, value: fatMass / kg * 100)
        }
        XCTAssertNil(trend(noisy))
    }

    func testPersonalizedCurvesRespectBMIAndUseOneConsistentCompositionSeries() throws {
        let model = try XCTUnwrap(trend(history()))
        let body = try XCTUnwrap(model.readings.last?.body)
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 6, to: start)!
        let points = model.projection(from: body, startingAt: start, until: end, gapKcal: 500,
                                      minimumWeightKg: body.weightKg - 2, calendar: calendar)
        XCTAssertEqual(points.first?.body, body)
        XCTAssertTrue(points.allSatisfy { $0.body.weightKg >= body.weightKg - 2 })
        XCTAssertLessThan(try XCTUnwrap(points.last?.date), end)
        XCTAssertNotNil(BodyCompositionTrend.entryDate(in: points, upperWeight: body.weightKg - 1))
        let flat = model.projection(from: body, startingAt: start, until: end, gapKcal: 0,
                                    minimumWeightKg: 56, calendar: calendar)
        XCTAssertTrue(flat.allSatisfy { $0.body == body })
        XCTAssertNil(BodyCompositionTrend.entryDate(in: flat, upperWeight: body.weightKg - 1))
        XCTAssertNil(model.advance(body, deficitKcal: .nan))
    }

    private func calibrationInputs(_ input: History, gap: Int) -> (resting: [HealthMeasurePoint], active: [HealthMeasurePoint], logs: [FoodLog]) {
        let resting = input.weights.map { HealthMeasurePoint(date: $0.date, value: 1800) }
        let active = input.weights.map { HealthMeasurePoint(date: $0.date, value: 700) }
        let logs = input.weights.enumerated().map { index, point in
            let parts = calendar.dateComponents([.year, .month, .day], from: point.date)
            return FoodLog(id: "\(index)", foodId: "food", foodName: "Daily food", serving: "Day", quantity: 1,
                kcal: 2500 - gap, localDate: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                loggedAt: ISO8601DateFormatter().string(from: point.date))
        }
        return (resting, active, logs)
    }

    func testFatBasedEnergyFitAvoidsMistakingLeanPreservationForEnergyError() throws {
        let input = history(fatLoss: 500 / BodyCompositionTrend.fatKcalPerKg)
        let model = try XCTUnwrap(trend(input))
        let energy = calibrationInputs(input, gap: 500)
        let accountStart = calendar.date(byAdding: .day, value: -42, to: now)!
        let plain = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: accountStart, now: now, calendar: calendar))
        let composed = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: accountStart, now: now, calendar: calendar, composition: model))
        XCTAssertLessThan(plain.correctionKcal, -40)
        XCTAssertGreaterThan(composed.correctionKcal, plain.correctionKcal)
        XCTAssertEqual(composed.correctionKcal, plain.correctionKcal * (1 - model.confidence), accuracy: 0.001)
        XCTAssertEqual(composed.diagnostics?.usesBodyComposition, true)
        let budget = CalorieBudget(tdeeKcal: 2500, deficitPercent: 20)
        XCTAssertEqual(budget.allowanceKcal, 2000)
    }

    func testRecompositionEnergyFitRecognizesLossWithStableScaleWeight() throws {
        let input = history(leanGain: 0.04)
        let model = try XCTUnwrap(trend(input))
        let energy = calibrationInputs(input, gap: 305)
        let composed = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: input.weights.first!.date,
            now: now, calendar: calendar, composition: model))
        XCTAssertEqual(composed.diagnostics?.usesBodyComposition, true)
        let tissueGap = -model.fatChangeKgPerDay * BodyCompositionTrend.fatKcalPerKg
            - model.leanChangeKgPerDay * BodyCompositionTrend.leanKcalPerKg
        let data = try XCTUnwrap(composed.diagnostics)
        XCTAssertEqual(composed.correctionKcal, (tissueGap * model.confidence - 305) * data.influence, accuracy: 1)
        XCTAssertGreaterThan(data.weightEquivalentDeficitKcal, 150)
    }

    func testOldHistoryCannotRescueSparseRecentComposition() {
        var input = history(fatLoss: 500 / BodyCompositionTrend.fatKcalPerKg)
        let cutoff = calendar.date(byAdding: .day, value: -42, to: calendar.startOfDay(for: now))!
        input.fat = input.fat.enumerated().filter { $0.element.date < cutoff || $0.offset % 14 == 13 }.map(\.element)
        XCTAssertNil(trend(input))
    }

    func testOlderOpposingTrendAndTodaysReadingsCannotChangeTheRecentFit() throws {
        let recent = history(days: 42, fatLoss: 0.03, leanGain: 0.01)
        var combined = recent
        let old = history(days: 200, fatLoss: -0.1, leanGain: -0.02)
        let cutoff = calendar.date(byAdding: .day, value: -42, to: calendar.startOfDay(for: now))!
        combined.weights += old.weights.filter { $0.date < cutoff }
        combined.fat += old.fat.filter { $0.date < cutoff }
        combined.weights.append(.init(date: now, value: 100))
        combined.fat.append(.init(date: now, value: 45))
        let expected = try XCTUnwrap(trend(recent))
        let actual = try XCTUnwrap(trend(combined, since: old.weights.first!.date))
        XCTAssertEqual(actual.window, expected.window)
        XCTAssertEqual(actual.readings.count, 42)
        XCTAssertEqual(actual.weekCount, 6)
        XCTAssertEqual(actual.fatChangeKgPerDay, expected.fatChangeKgPerDay, accuracy: 0.000001)
        XCTAssertEqual(actual.leanChangeKgPerDay, expected.leanChangeKgPerDay, accuracy: 0.000001)
        XCTAssertEqual(actual.confidence, expected.confidence, accuracy: 0.000001)
    }

    func testEnergyFitRejectsACompositionTrendFromADifferentWindow() throws {
        let input = history()
        let model = try XCTUnwrap(trend(input))
        let energy = calibrationInputs(input, gap: 500)
        let laterStart = calendar.date(byAdding: .day, value: -32, to: now)!
        let plain = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: laterStart, now: now, calendar: calendar))
        let mismatched = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: laterStart, now: now, calendar: calendar, composition: model))
        XCTAssertEqual(mismatched.diagnostics?.usesBodyComposition, false)
        XCTAssertEqual(mismatched.correctionKcal, plain.correctionKcal, accuracy: 0.000001)
    }

    func testDisplayedCompositionWeightsAndForbesSplitMatchTheActualModel() throws {
        let model = try XCTUnwrap(trend(history(leanGain: 0.01)))
        let weight = model.weighting
        XCTAssertEqual(weight.historyFactor, 1, accuracy: 0.000001)
        XCTAssertEqual(model.confidence, weight.historyFactor * weight.readingFactor * weight.consistency)
        let body = try XCTUnwrap(model.readings.last?.body)
        let split = model.split(for: body)
        XCTAssertEqual(split.forbesLeanPerFat, 10.4 / body.fatMassKg)
        XCTAssertLessThan(split.personalLeanPerFat, 0)
        XCTAssertEqual(split.usedLeanPerFat,
            max(-1, split.forbesLeanPerFat * (1 - split.personalShare) + split.personalLeanPerFat * split.personalShare))
        let energy = 1.0
        let after = try XCTUnwrap(model.advance(body, deficitKcal: energy))
        let fatLost = body.fatMassKg - after.fatMassKg
        let leanLost = body.fatFreeMassKg - after.fatFreeMassKg
        XCTAssertEqual(leanLost / fatLost, split.usedLeanPerFat, accuracy: 0.000001)
        let lowerFat = try XCTUnwrap(ForbesBodyComposition(weightKg: body.weightKg - 5, fatMassKg: body.fatMassKg - 5))
        XCTAssertLessThan(model.split(for: lowerFat).personalShare, split.personalShare)
    }

    func testCompositionHistoryUsesTheSameUsableWeekRuleAsEnergyCalibration() throws {
        for (days, weeks, expected) in [(32, 4, 4.0 / 6), (35, 5, 5.0 / 6), (42, 6, 1.0)] {
            let input = history(days: days)
            let model = try XCTUnwrap(trend(input))
            let energy = calibrationInputs(input, gap: 500)
            let result = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
                active: energy.active, logs: energy.logs, since: input.weights.first!.date,
                now: now, calendar: calendar, composition: model))
            let energyWeight = try XCTUnwrap(result.diagnostics?.weighting)
            XCTAssertEqual(model.weekCount, weeks)
            XCTAssertEqual(model.weighting.weeks, weeks)
            XCTAssertEqual(model.weighting.historyFactor, expected, accuracy: 0.000001)
            XCTAssertEqual(model.weighting.historyFactor, energyWeight.historyFactor)
        }
    }

    func testThreeMissingFatDaysDoNotReduceFullSixWeekHistoryWeight() throws {
        var input = history(days: 42)
        input.fat = input.fat.enumerated().filter { ![4, 18, 32].contains($0.offset) }.map(\.element)
        let model = try XCTUnwrap(trend(input))
        XCTAssertEqual(model.readings.count, 39)
        XCTAssertEqual(model.weekCount, 6)
        XCTAssertEqual(model.weighting.historyFactor, 1)
        XCTAssertEqual(model.weighting.readingFactor, 1)
        XCTAssertEqual(model.confidence, 1, accuracy: 0.000001)
    }

    func testPairedHistoryCountsAreAvailableEvenWithoutAReliableTrend() throws {
        var input = history(days: 10)
        input.fat.removeLast()
        let window = try XCTUnwrap(ForecastCalibration.historyWindow(since: input.weights.first!.date, now: now, calendar: calendar))
        let pairs = BodyCompositionTrend.pairedReadings(weights: input.weights, bodyFat: input.fat, within: window, calendar: calendar)
        XCTAssertEqual(pairs.count, 9)
        XCTAssertNil(trend(input))
    }

    func testAccountStartBoundsBothFitsAndUsesTheSameCompletedWeekGroups() throws {
        let input = history()
        let start = calendar.date(byAdding: .day, value: -32, to: now)!
        let model = try XCTUnwrap(trend(input, since: start))
        let energy = calibrationInputs(input, gap: 500)
        let calibration = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: start, now: now, calendar: calendar, composition: model))
        let data = try XCTUnwrap(calibration.diagnostics)
        XCTAssertEqual(model.window.start, data.inputStart)
        XCTAssertEqual(model.window.end, data.inputEnd)
        XCTAssertEqual(model.readings.count, 32)
        XCTAssertEqual(model.weekCount, 4)
        XCTAssertEqual(model.weekCount, calibration.weightWeeks)
        XCTAssertTrue(model.readings.allSatisfy { $0.date >= data.inputStart && $0.date < data.inputEnd })
        // Longer pre-account history must not calibrate a new tracking period.
        let newStart = calendar.date(byAdding: .day, value: -10, to: now)!
        XCTAssertNil(trend(input, since: newStart))
        XCTAssertNil(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: newStart, now: now, calendar: calendar))
        XCTAssertNil(trend(input, since: now.addingTimeInterval(86400)))
    }
}
