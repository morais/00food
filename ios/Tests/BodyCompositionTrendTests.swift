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

    private func trend(_ input: History) -> BodyCompositionTrend? {
        BodyCompositionTrend.make(weights: input.weights, bodyFat: input.fat, now: now, calendar: calendar)
    }

    func testFullHistoryLearnsLeanPreservationAndUsesDatesBeforeTheEnergyWindow() throws {
        let input = history()
        let model = try XCTUnwrap(trend(input))
        XCTAssertEqual(model.readings.count, 140)
        XCTAssertEqual(model.firstDate, input.fat.first?.date)
        XCTAssertEqual(model.fatChangeKgPerDay, -0.04, accuracy: 0.000001)
        XCTAssertEqual(model.leanChangeKgPerDay, 0, accuracy: 0.000001)
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
        XCTAssertLessThan(body.weightKg - after.weightKg, 0.3)
    }

    func testRecentSpikeDoesNotReplaceTheFullTrendAndDuplicateDaysCountOnce() throws {
        var input = history()
        for index in (input.fat.count - 7)..<input.fat.count { input.fat[index] = .init(date: input.fat[index].date, value: input.fat[index].value + 2) }
        let date = input.fat[20].date.addingTimeInterval(-60)
        input.fat.append(.init(date: date, value: 99))
        input.fat.append(.init(date: now.addingTimeInterval(86400), value: 1))
        let model = try XCTUnwrap(trend(input))
        XCTAssertEqual(model.readings.count, 140)
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
        XCTAssertEqual(composed.correctionKcal, 0, accuracy: 0.001)
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
        XCTAssertEqual(composed.correctionKcal, 0, accuracy: 1)
    }

    func testOldCompositionHistoryCanTeachSplitWithoutInventingRecentEnergyMeasurements() throws {
        var input = history(fatLoss: 500 / BodyCompositionTrend.fatKcalPerKg)
        let cutoff = calendar.date(byAdding: .day, value: -42, to: now)!
        input.fat = input.fat.enumerated().filter { $0.element.date < cutoff || $0.offset % 14 == 13 }.map(\.element)
        let model = try XCTUnwrap(trend(input))
        let energy = calibrationInputs(input, gap: 500)
        let plain = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: input.weights.first!.date, now: now, calendar: calendar))
        let composed = try XCTUnwrap(ForecastCalibration.make(weights: input.weights, resting: energy.resting,
            active: energy.active, logs: energy.logs, since: input.weights.first!.date,
            now: now, calendar: calendar, composition: model))
        XCTAssertEqual(composed.diagnostics?.usesBodyComposition, false)
        XCTAssertEqual(composed.correctionKcal, plain.correctionKcal, accuracy: 0.001)
    }
}
