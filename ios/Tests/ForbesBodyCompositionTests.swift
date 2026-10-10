import XCTest
@testable import ZeroZeroFood

final class ForbesBodyCompositionTests: XCTestCase {
    func testExampleAndIntegratedMassConservation() throws {
        let start = try XCTUnwrap(ForbesBodyComposition(weightKg: 85, bodyFatPercentage: 26.8))
        XCTAssertEqual(start.fatMassKg, 22.78, accuracy: 1e-9)
        XCTAssertEqual(start.fatFreeMassKg, 62.22, accuracy: 1e-9)
        XCTAssertEqual(start.fatFraction, 0.68655816757, accuracy: 1e-9)
        let end = try XCTUnwrap(start.losing(sustainedWeightKg: 1))
        let fatLoss = start.fatMassKg - end.fatMassKg
        let fatFreeLoss = start.fatFreeMassKg - end.fatFreeMassKg
        XCTAssertEqual(fatLoss, 0.68328049045, accuracy: 1e-8)
        XCTAssertEqual(fatFreeLoss, 0.31671950955, accuracy: 1e-8)
        XCTAssertEqual(fatLoss + fatFreeLoss, 1, accuracy: 1e-9)
        XCTAssertLessThan(end.fatFraction, start.fatFraction)
        // Independent integrated identity verifies the numerical model rather
        // than repeating the stepping implementation in the test.
        XCTAssertEqual(fatLoss + 10.4 * log(start.fatMassKg / end.fatMassKg), 1, accuracy: 1e-8)
    }

    func testIterationIsConsistentAndDoesNotUseFixedInitialFraction() throws {
        let start = try XCTUnwrap(ForbesBodyComposition(weightKg: 85, bodyFatPercentage: 26.8))
        let first = try XCTUnwrap(start.losing(sustainedWeightKg: 5))
        let second = try XCTUnwrap(first.losing(sustainedWeightKg: 5))
        let entire = try XCTUnwrap(start.losing(sustainedWeightKg: 10))
        XCTAssertEqual(second.fatMassKg, entire.fatMassKg, accuracy: 1e-8)
        XCTAssertEqual(second.weightKg, 75, accuracy: 1e-8)
        XCTAssertLessThan(first.fatMassKg - second.fatMassKg, start.fatMassKg - first.fatMassKg)
        XCTAssertLessThan(start.fatMassKg - entire.fatMassKg, 10 * start.fatFraction)
        XCTAssertGreaterThan(entire.fatFreeMassKg, 0)
        XCTAssertEqual(try XCTUnwrap(start.losing(sustainedWeightKg: 0)), start)
        XCTAssertNil(ForbesBodyComposition(weightKg: 85, bodyFatPercentage: 0))
        XCTAssertNil(ForbesBodyComposition(weightKg: 85, bodyFatPercentage: .nan))
        XCTAssertNil(start.losing(sustainedWeightKg: 85))
    }

    func testMedianRejectsOneDaySpikeAndUsesOneReadingPerLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10)))
        var fat: [HealthMeasurePoint] = []
        var weight: [HealthMeasurePoint] = []
        for offset in 0...6 {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: now))
            fat.append(HealthMeasurePoint(date: date, value: offset == 0 ? 20 : 26.8))
            weight.append(HealthMeasurePoint(date: date, value: offset == 0 ? 82 : 85))
        }
        // A second reading on the same morning must not count as another day.
        fat.append(HealthMeasurePoint(date: now.addingTimeInterval(-3600), value: 10))
        weight.append(HealthMeasurePoint(date: now.addingTimeInterval(-3600), value: 80))
        let baseline = try XCTUnwrap(BodyCompositionBaseline.make(bodyFat: fat, weight: weight,
            latestBodyFat: fat[0], latestWeight: weight[0], fallbackWeightKg: 90, now: now, calendar: calendar))
        XCTAssertEqual(baseline.date, now)
        XCTAssertEqual(baseline.fatReadingDays, 7)
        XCTAssertEqual(baseline.weightReadingDays, 7)
        XCTAssertEqual(baseline.composition.weightKg, 85)
        XCTAssertEqual(baseline.composition.bodyFatPercentage, 26.8, accuracy: 1e-9)
        XCTAssertEqual(baseline.composition.fatMassKg, 22.78, accuracy: 1e-9)
        XCTAssertEqual(BodyCompositionBaseline.smoothedWeight(weight, latest: weight[0], now: now,
                                                               calendar: calendar), 85)
        // A sustained run of new body-fat readings recalibrates the baseline.
        let changed = fat.map { HealthMeasurePoint(date: $0.date,
            value: $0.date >= now.addingTimeInterval(-3 * 86400) ? 25 : $0.value) }
        let refreshed = try XCTUnwrap(BodyCompositionBaseline.make(bodyFat: changed, weight: weight,
            latestBodyFat: nil, latestWeight: nil, fallbackWeightKg: 90, now: now, calendar: calendar))
        XCTAssertEqual(refreshed.composition.bodyFatPercentage, 25, accuracy: 1e-9)
    }

    func testBodyFatIsRequiredAndOldOrFutureWeightsDoNotDistortWindow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let fat = HealthMeasurePoint(date: now, value: 26.8)
        XCTAssertNil(BodyCompositionBaseline.make(bodyFat: [], weight: [], latestBodyFat: nil,
            latestWeight: nil, fallbackWeightKg: 85, now: now))
        let baseline = try XCTUnwrap(BodyCompositionBaseline.make(bodyFat: [fat], weight: [
            HealthMeasurePoint(date: now.addingTimeInterval(-20 * 86400), value: 100),
            HealthMeasurePoint(date: now, value: 85),
            HealthMeasurePoint(date: now.addingTimeInterval(86400), value: 50),
        ], latestBodyFat: nil, latestWeight: nil, fallbackWeightKg: 90, now: now))
        XCTAssertEqual(baseline.composition.weightKg, 85)
        XCTAssertEqual(baseline.fatReadingDays, 1)
        XCTAssertEqual(baseline.weightReadingDays, 1)
    }

    func testACEForecastUsesForbesAndAgreesWithProjectedTargetPercentage() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let points = ProgressProjection.bodyFatProjection(anchor: HealthMeasurePoint(date: now, value: 26.8),
            startWeightKg: 85, gapKcal: 500, minimumWeightKg: 56,
            until: now.addingTimeInterval(183 * 86400))
        let crossing = try XCTUnwrap(ACEThresholdForecast.crossingDate(for: 25, in: points))
        let elapsed = crossing.timeIntervalSince(now) / 86400
        let targetWeight = 85 - elapsed * 500 / 7700
        let percentage = try XCTUnwrap(ProgressProjection.bodyFatPercent(startWeightKg: 85,
            startBodyFatPercent: 26.8, projectedWeightKg: targetWeight))
        XCTAssertEqual(percentage, 25, accuracy: 0.0001)
        // The former all-fat assumption reaches 25% after 2.04 kg. Forbes
        // reaches it later because some of the sustained loss is fat-free mass.
        XCTAssertGreaterThan(85 - targetWeight, 2.04)
    }
}
