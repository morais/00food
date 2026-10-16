import XCTest
@testable import ZeroZeroFood

final class MiddayFeedbackTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 10, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                          hour: hour, minute: minute))!
    }

    func testMiddayHealthWindowIncludesTodayAndKeepsSampleCutoff() throws {
        let capture = date(16, hour: 18, minute: 45)
        let window = try XCTUnwrap(DailyFeedbackHealthWindow(from: date(10), through: capture,
                                                            capturedAt: capture, calendar: calendar))
        XCTAssertEqual(window.days, (10...16).map { date($0) })
        XCTAssertEqual(window.queryEnd, capture)
        XCTAssertEqual(window.start, date(10))
    }

    func testSinglePartialDayStillProducesHealthRow() throws {
        let capture = date(16, hour: 8)
        let window = try XCTUnwrap(DailyFeedbackHealthWindow(from: capture, through: capture,
                                                            capturedAt: capture, calendar: calendar))
        XCTAssertEqual(window.days, [date(16)])
        XCTAssertEqual(window.queryEnd, capture)
    }

    func testCompletedDayWindowKeepsAllSevenDays() throws {
        let window = try XCTUnwrap(DailyFeedbackHealthWindow(from: date(10), through: date(16),
                                                            calendar: calendar))
        XCTAssertEqual(window.days, (10...16).map { date($0) })
        XCTAssertEqual(window.queryEnd, date(17))
    }

    func testMiddayHealthWindowIncludesTodayAcrossDaylightSavingChange() throws {
        let capture = date(26, hour: 8)
        let window = try XCTUnwrap(DailyFeedbackHealthWindow(from: date(20), through: capture,
                                                            capturedAt: capture, calendar: calendar))
        XCTAssertEqual(window.days, (20...26).map { date($0) })
        XCTAssertEqual(window.queryEnd, capture)
        XCTAssertEqual(date(26).timeIntervalSince(date(25)), 25 * 60 * 60)
    }

    func testMiddayRequestKeepsScopeCaptureTimeAndRestingEstimateOffline() throws {
        let upload = DailyFeedbackUpload(id: "midday", localDate: "2026-10-16", timeZone: "Europe/Lisbon",
            healthDays: [], userInstructions: "Help plan dinner", kind: "midday",
            capturedAt: "2026-10-16T12:00:00.123Z", restingEstimateKcal: 1800)
        let restored = try JSONDecoder().decode(DailyFeedbackUpload.self, from: JSONEncoder().encode(upload))
        XCTAssertEqual(restored.kind, "midday")
        XCTAssertEqual(restored.capturedAt, upload.capturedAt)
        XCTAssertEqual(restored.restingEstimateKcal, 1800)
        let request = DailyFeedbackRequest(id: "midday", localDate: upload.localDate, state: "ready",
            feedback: "Dinner ideas", createdAt: "now", updatedAt: "now", needsRefresh: true, kind: "midday")
        XCTAssertTrue(request.isMidday)
        XCTAssertFalse(request.canRequestNewReview(enabled: true, today: "2026-10-17"))
    }

    func testOlderReviewsRemainCompletedDayReviews() throws {
        let data = Data(#"{"id":"old","localDate":"2026-10-15","state":"ready","feedback":"Review","createdAt":"now","updatedAt":"now"}"#.utf8)
        let request = try JSONDecoder().decode(DailyFeedbackRequest.self, from: data)
        XCTAssertFalse(request.isMidday)
    }
}
