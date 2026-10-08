import XCTest
@testable import ZeroZeroFood

final class DailyFeedbackScheduleTests: XCTestCase {
    @MainActor func testBackgroundTaskIsPermittedAndFetchIsEnabled() {
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(identifiers?.contains(DailyFeedbackBackground.identifier) == true)
        XCTAssertTrue(modes?.contains("fetch") == true)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testBeforeMidnightSchedulesNextCompletedDay() {
        XCTAssertEqual(DailyFeedbackSchedule.nextRefresh(after: date(2026, 10, 8, 23, 0), calendar: calendar),
                       date(2026, 10, 9, 0, 15))
    }

    func testEarlyMorningUsesTodayAndCompletedRunUsesTomorrow() {
        XCTAssertEqual(DailyFeedbackSchedule.nextRefresh(after: date(2026, 10, 9, 0, 5), calendar: calendar),
                       date(2026, 10, 9, 0, 15))
        XCTAssertEqual(DailyFeedbackSchedule.nextRefresh(after: date(2026, 10, 9, 0, 15), calendar: calendar),
                       date(2026, 10, 10, 0, 15))
    }

    func testDaylightSavingChangeKeepsLocalTime() {
        let before = date(2026, 10, 25, 0, 15)
        let next = DailyFeedbackSchedule.nextRefresh(after: before, calendar: calendar)
        XCTAssertEqual(next, date(2026, 10, 26, 0, 15))
        XCTAssertEqual(next.timeIntervalSince(before), 25 * 60 * 60)
    }
}
