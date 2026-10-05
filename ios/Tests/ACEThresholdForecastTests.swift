import XCTest
@testable import ZeroZeroFood

final class ACEThresholdForecastTests: XCTestCase {
    func testInterpolatesCrossingBetweenWeeklyProjectionPoints() {
        let start = Date(timeIntervalSince1970: 0)
        let week = 7 * 24 * 60 * 60.0
        let points = [HealthMeasurePoint(date: start, value: 30),
                      HealthMeasurePoint(date: start.addingTimeInterval(week), value: 20)]

        let crossing = ACEThresholdForecast.crossingDate(for: 25, in: points)
        XCTAssertEqual(crossing?.timeIntervalSince1970 ?? -1, week / 2, accuracy: 1)
        XCTAssertNil(ACEThresholdForecast.crossingDate(for: 18, in: points))
    }
}
