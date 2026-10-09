import XCTest
@testable import ZeroZeroFood

final class ProgressProjectionTests: XCTestCase {
    func testFatProjectionStartsAtLastChartDotRatherThanIndividualReadingOrToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        let dot = HealthMeasurePoint(date: start, value: 26.2)
        let individual = HealthMeasurePoint(date: start.addingTimeInterval(12 * 3600), value: 24.9)
        let anchor = try XCTUnwrap(ProgressProjection.bodyFatAnchor(
            history: [dot, HealthMeasurePoint(date: previous, value: 27)], fallback: individual))
        let end = calendar.date(byAdding: .month, value: 6, to: start)!
        let points = ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: 80,
            gapKcal: 550, minimumWeightKg: 56, until: end, calendar: calendar)
        XCTAssertEqual(points.first?.date, dot.date)
        XCTAssertEqual(points.first?.value, dot.value)
        XCTAssertEqual(points.last?.date, end)
        XCTAssertLessThan(try XCTUnwrap(points.last?.value), dot.value)
        // Category dates must now start with the plotted 26.2%, above 25%.
        XCTAssertNotNil(ACEThresholdForecast.crossingDate(for: 25, in: points))
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

    func testBodyFatProjectionTreatsWeightLostAsFat() {
        // 80 kg at 25% fat starts with 20 kg of fat. After losing 5 kg of fat,
        // 15 kg of fat remains in a 75 kg body: 20%.
        XCTAssertEqual(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 75), 20, accuracy: 0.001)
        XCTAssertEqual(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 80), 25, accuracy: 0.001)
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
