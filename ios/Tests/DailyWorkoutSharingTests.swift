import XCTest
@testable import ZeroZeroFood

final class DailyWorkoutSharingTests: XCTestCase {
    func testBothReviewAndSharingOptInsAreRequiredIncludingAfterOfflineQueueing() throws {
        let workout = DailyWorkoutSummary(id: UUID().uuidString, activity: "Running",
            startedAt: "2026-10-14T07:00:00Z", endedAt: "2026-10-14T07:30:00Z",
            durationMinutes: 30, activeKcal: 300, distanceMeters: 5_000)
        let day = DailyHealthDay(localDate: "2026-10-14", activeKcal: 700, restingKcal: 1800,
            waterMl: 2000, weightKg: 80, bodyFatPercent: 25, workouts: [workout], workoutsTruncated: false)
        let upload = DailyFeedbackUpload(id: "request", localDate: day.localDate, timeZone: "UTC", healthDays: [day])
        let restored = try JSONDecoder().decode(DailyFeedbackUpload.self, from: JSONEncoder().encode(upload))
        XCTAssertEqual(restored.healthDays[0].workouts, [workout])
        for (reviews, sharing) in [(false, false), (true, false), (false, true)] {
            let filtered = DailyWorkoutSharing.filter(restored.healthDays, reviewsEnabled: reviews, sharingEnabled: sharing)
            XCTAssertNil(filtered[0].workouts)
            XCTAssertNil(filtered[0].workoutsTruncated)
            XCTAssertEqual(filtered[0].activeKcal, 700)
            XCTAssertEqual(filtered[0].restingKcal, 1800)
            XCTAssertEqual(filtered[0].waterMl, 2000)
        }
        XCTAssertEqual(DailyWorkoutSharing.filter(restored.healthDays, reviewsEnabled: true,
                                                  sharingEnabled: true)[0].workouts, [workout])
    }

    func testOlderHealthSummariesDoNotImplyWorkoutSharing() throws {
        let data = Data(#"{"localDate":"2026-10-14","activeKcal":700}"#.utf8)
        let day = try JSONDecoder().decode(DailyHealthDay.self, from: data)
        XCTAssertNil(day.workouts)
        XCTAssertNil(day.workoutsTruncated)
    }
}
