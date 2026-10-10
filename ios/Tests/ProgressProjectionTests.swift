import XCTest
@testable import ZeroZeroFood

final class ProgressProjectionTests: XCTestCase {
    func testPacePreviewRecomputesSixMonthWeightAndBMIEntry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = calendar.date(byAdding: .month, value: 6, to: now)!
        let range = ProgressProjection.healthyWeightRange(for: 175)
        XCTAssertEqual(range.lowerBound, 56.65625, accuracy: 0.00001)
        var previousEnd = 81.0
        for level in DeficitLevel.allCases {
            let gap = CalorieBudget(tdeeKcal: 2600, deficitPercent: level.rawValue).gapKcal
            let points = ProgressProjection.projectedWeight(from: 80, gap: gap, minimum: range.lowerBound,
                                                            until: end, now: now, calendar: calendar)
            XCTAssertEqual(points.first?.value, 80)
            XCTAssertEqual(points.last?.date, end)
            let finalWeight = try XCTUnwrap(points.last?.value)
            XCTAssertLessThan(finalWeight, previousEnd)
            previousEnd = finalWeight
            let entry = ProgressProjection.estimatedBMIEntryDate(from: 80, gap: gap,
                upperBound: range.upperBound, until: end, now: now, calendar: calendar)
            if level == .maintain { XCTAssertEqual(finalWeight, 80); XCTAssertNil(entry) }
            else { XCTAssertNotNil(entry) }
        }
    }

    func testWeightIllustrationStopsAtBMIFloorForBothPreviewAndProgress() {
        let now = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .month, value: 6, to: now)!
        let points = ProgressProjection.projectedWeight(from: 60, gap: 700, minimum: 56,
                                                        until: end, now: now)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.allSatisfy { $0.value >= 56 })
        XCTAssertLessThan(points.last!.date, end)
    }

    func testFatProjectionStartsAtLastRecordedChartDotAndTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 30))!
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        let dot = HealthMeasurePoint(date: start, value: 24.9)
        let anchor = try XCTUnwrap(ProgressProjection.bodyFatAnchor(
            history: [dot, HealthMeasurePoint(date: previous, value: 27)], fallback: dot))
        let end = calendar.startOfDay(for: calendar.date(byAdding: .month, value: 6, to: start)!)
        let points = ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: 80,
            gapKcal: 550, minimumWeightKg: 56, until: end, calendar: calendar)
        XCTAssertEqual(points.first?.date, dot.date)
        XCTAssertEqual(points.first?.value, dot.value)
        XCTAssertEqual(points.last?.date, end)
        XCTAssertLessThan(try XCTUnwrap(points.last?.value), dot.value)
        XCTAssertNil(ACEThresholdForecast.crossingDate(for: 25, in: points))
        XCTAssertNotNil(ACEThresholdForecast.crossingDate(for: 20, in: points))
        XCTAssertNil(ACEThresholdForecast.crossingDate(for: 18, in: points),
                     "Forbes reaches lower percentages later than the former all-fat illustration")
    }

    func testFatProjectionFallbackKeepsReadingTimestampAndMaintainIsFlat() throws {
        let dot = HealthMeasurePoint(date: Date(timeIntervalSince1970: 100000), value: 24.9)
        let anchor = try XCTUnwrap(ProgressProjection.bodyFatAnchor(history: [], fallback: dot))
        let points = ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: 80,
            gapKcal: 0, minimumWeightKg: 56, until: dot.date.addingTimeInterval(14 * 86400))
        XCTAssertEqual(points.first?.date, dot.date)
        for point in points { XCTAssertEqual(point.value, dot.value, accuracy: 0.000001) }
        XCTAssertNil(ProgressProjection.bodyFatAnchor(history: [], fallback: nil))
    }

    func testBodyFatProjectionUsesChangingForbesFraction() throws {
        // Integrated Forbes: loss = (FM0 - FM1) + 10.4 * ln(FM0 / FM1).
        // At 80 kg / 25%, a 5 kg sustained loss partitions into ~3.192 kg fat.
        XCTAssertEqual(try XCTUnwrap(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 75)), 22.41093356, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 80)), 25, accuracy: 0.001)
    }

    func testOnlyCrossedACEBoundariesAreAddedForEachProfile() {
        let male = ProgressProjection.visibleACEBoundaries(for: "male", projectedPercentages: [28, 16])
        XCTAssertEqual(male.map(\.percentage), [25, 18])
        let female = ProgressProjection.visibleACEBoundaries(for: "female", projectedPercentages: [29, 19])
        XCTAssertEqual(female.map(\.percentage), [32, 25, 21])
        XCTAssertEqual(ProgressProjection.visibleACEBoundaries(for: "neutral", projectedPercentages: [29, 19]), [])
        XCTAssertEqual(ProgressProjection.visibleACEBoundaries(for: "male", projectedPercentages: []),
                       [ACEBodyFatBoundary(category: "Obesity", percentage: 25, isObesity: true)])
    }

}
