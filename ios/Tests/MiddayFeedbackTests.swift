import XCTest
@testable import ZeroZeroFood

final class MiddayFeedbackTests: XCTestCase {
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
