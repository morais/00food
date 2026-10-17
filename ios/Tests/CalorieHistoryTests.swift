import XCTest
@testable import ZeroZeroFood

final class CalorieHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
    }

    func testAverageUsesLastSevenCompletedCalendarDays() throws {
        let points = (1...17).map { day in
            DailyCalorieBalance(date: date(day), eaten: day == 17 ? 0 : day * 100, allowance: 2000, tdeeKcal: 2500)
        }
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.dayCount, 7)
        XCTAssertEqual(average.remainingKcalPerDay, 700, accuracy: 0.001)
        XCTAssertEqual(average.remainingPercent, 35, accuracy: 0.001)
    }

    func testMixedBalancesUseCombinedAllowanceForPercentage() throws {
        let points = [DailyCalorieBalance(date: date(15), eaten: 1800, allowance: 2000, tdeeKcal: 2500),
                      DailyCalorieBalance(date: date(16), eaten: 2000, allowance: 1000, tdeeKcal: 1250)]
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.dayCount, 2)
        XCTAssertEqual(average.remainingKcalPerDay, -400, accuracy: 0.001)
        XCTAssertEqual(average.remainingPercent, -800.0 / 3000 * 100, accuracy: 0.001)
        XCTAssertTrue(average.label.contains("over allowance"))
        XCTAssertTrue(average.label.hasPrefix("2-day average"))
    }

    func testBalancedDaysOffsetToZero() throws {
        let points = [DailyCalorieBalance(date: date(15), eaten: 1800, allowance: 2000, tdeeKcal: 2500),
                      DailyCalorieBalance(date: date(16), eaten: 2200, allowance: 2000, tdeeKcal: 2500)]
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.remainingKcalPerDay, 0)
        XCTAssertEqual(average.remainingPercent, 0)
        XCTAssertEqual(average.tdeeDeficitPercent, 20, accuracy: 0.001)
        XCTAssertTrue(average.label.contains("on allowance"))
    }

    func testTDEEDeficitIsSeparateFromGoalAndUsesCombinedExpenditure() throws {
        let points = [DailyCalorieBalance(date: date(15), eaten: 1800, allowance: 2000, tdeeKcal: 2500),
                      DailyCalorieBalance(date: date(16), eaten: 900, allowance: 1000, tdeeKcal: 1500)]
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.remainingPercent, 10, accuracy: 0.001)
        XCTAssertEqual(average.tdeeDeficitPercent, 32.5, accuracy: 0.001)
        XCTAssertTrue(average.tdeeLabel.contains("deficit vs TDEE"))
    }

    func testOverGoalCanStillBeBelowTDEE() throws {
        let points = [DailyCalorieBalance(date: date(16), eaten: 2300, allowance: 2000, tdeeKcal: 2500)]
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.remainingPercent, -15, accuracy: 0.001)
        XCTAssertEqual(average.tdeeDeficitPercent, 8, accuracy: 0.001)
        XCTAssertTrue(average.label.contains("over allowance"))
        XCTAssertTrue(average.tdeeLabel.contains("deficit vs TDEE"))
    }

    func testEatingAboveTDEEReportsSurplus() throws {
        let points = [DailyCalorieBalance(date: date(16), eaten: 2700, allowance: 2000, tdeeKcal: 2500)]
        let average = try XCTUnwrap(CalorieBalanceAverage.lastSevenCompletedDays(in: points,
            now: date(17), calendar: calendar))
        XCTAssertEqual(average.tdeeDeficitPercent, -8, accuracy: 0.001)
        XCTAssertTrue(average.tdeeLabel.contains("surplus vs TDEE"))
    }

    func testNoCompletedDaysOrValidAllowanceHasNoAverage() {
        let points = [DailyCalorieBalance(date: date(16), eaten: 100, allowance: 0, tdeeKcal: 0),
                      DailyCalorieBalance(date: date(17), eaten: 100, allowance: 2000, tdeeKcal: 2500)]
        XCTAssertNil(CalorieBalanceAverage.lastSevenCompletedDays(in: points, now: date(17), calendar: calendar))
        XCTAssertNil(CalorieBalanceAverage.lastSevenCompletedDays(in: [], now: date(17), calendar: calendar))
    }
}
