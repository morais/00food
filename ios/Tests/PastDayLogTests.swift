import XCTest
@testable import ZeroZeroFood

final class PastDayLogTests: XCTestCase {
    func testMealTimestampKeepsChosenLocalDayAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        let chosenDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 18, minute: 34)))
        let loggedAt = FoodDates.logTimestamp(on: chosenDay, now: now, calendar: calendar)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: loggedAt)
        XCTAssertEqual(parts.day, 24)
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 34)
        XCTAssertEqual(FoodDates.logTimestamp(on: nil, now: now), now)
        XCTAssertEqual(now.timeIntervalSince(loggedAt), 25 * 3600)
    }

    func testNewReviewRequiresAddedFoodEnabledReviewsAndCompletedDay() {
        var request = DailyFeedbackRequest(id: "request", localDate: "2026-10-09", state: "ready",
                                          feedback: "Earlier review", createdAt: "now", updatedAt: "now")
        XCTAssertFalse(request.canRequestNewReview(enabled: true, today: "2026-10-10"))
        request.needsRefresh = true
        XCTAssertTrue(request.canRequestNewReview(enabled: true, today: "2026-10-10"))
        XCTAssertFalse(request.canRequestNewReview(enabled: false, today: "2026-10-10"))
        XCTAssertFalse(request.canRequestNewReview(enabled: true, today: "2026-10-09"))
    }

    func testBackdatedFoodAndNewReviewSurviveOfflineRestartInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FoodLog(id: "log", foodId: "food", foodName: "Soup", serving: "1 bowl", quantity: 1,
                          kcal: 300, localDate: "2026-10-09", loggedAt: "2026-10-09T18:00:00Z",
                          createdAt: "2026-10-10T18:00:00Z")
        let upload = DailyFeedbackUpload(id: "new-review", localDate: log.localDate,
                                         timeZone: "Europe/Lisbon", healthDays: [], replacesRequestId: "old-review")
        let state = OfflineFoodState(snapshot: FoodSnapshot(startedAt: nil, profile: nil, foods: [],
                                                           logs: [log], estimations: []),
                                     operations: [.log(log), .requestDailyFeedback(upload)])
        try OfflineFoodDisk.save(state, for: "past-day-test", in: directory)
        let restored = try XCTUnwrap(OfflineFoodDisk.load(for: "past-day-test", in: directory))
        guard case .log(let restoredLog) = restored.operations[0],
              case .requestDailyFeedback(let restoredReview) = restored.operations[1] else {
            return XCTFail("The added food must sync before the updated review")
        }
        XCTAssertEqual(restoredLog, log)
        XCTAssertEqual(restoredReview.replacesRequestId, "old-review")
        XCTAssertEqual(restoredReview.localDate, log.localDate)
    }
}
