import XCTest
@testable import ZeroZeroFood

final class HealthHistoryTests: XCTestCase {
    func testSecondMorningWeighInReplacesFirstAndKeepsItsTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8))!
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 30))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: early)!
        let points = HealthHistory.lastReadingEachDay([
            HealthMeasurePoint(date: late, value: 24.9),
            HealthMeasurePoint(date: yesterday, value: 27),
            HealthMeasurePoint(date: early, value: 26.2),
        ], calendar: calendar)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.last?.value, 24.9)
        XCTAssertEqual(points.last?.date, late)
        let anchor = try XCTUnwrap(ProgressProjection.bodyFatAnchor(history: points, fallback: nil))
        XCTAssertEqual(anchor.value, 24.9)
        XCTAssertEqual(anchor.date, late)
    }

    func testUsesLocalCalendarDaysAndHandlesEmptyHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let dates = ["2026-10-08T21:30:00Z", "2026-10-08T23:30:00Z", "2026-10-09T00:20:00Z"]
            .map { ISO8601DateFormatter().date(from: $0)! }
        let points = HealthHistory.lastReadingEachDay(zip(dates, [27.0, 26.0, 25.0])
            .map { HealthMeasurePoint(date: $0.0, value: $0.1) }, calendar: calendar)
        XCTAssertEqual(points.map(\.value), [27, 25])
        XCTAssertEqual(points.last?.date, dates.last)
        XCTAssertTrue(HealthHistory.lastReadingEachDay([], calendar: calendar).isEmpty)
    }
}
