import XCTest
@testable import ZeroZeroFood

final class FoodUsageRankingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    private func rank(_ foods: [FoodItem], logs: [FoodLog]) -> [String] {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24))!
        return FoodUsageRanking.rank(foods, logs: logs, now: now, calendar: calendar).map(\.id)
    }

    private func food(_ name: String, uses: Int, lastUsedAt: String? = nil, dismissed: Bool = false) -> FoodItem {
        FoodItem(id: name, name: name, serving: "1 bowl", kcal: 200, source: "manual",
                 useCount: uses, lastUsedAt: lastUsedAt, dismissedAt: dismissed ? "2026-11-24T00:00:00Z" : nil,
                 createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-11-24T00:00:00Z")
    }

    private func log(_ id: String, food: String, day: String, quantity: Double = 1) -> FoodLog {
        FoodLog(id: id, foodId: food, foodName: food, serving: "1 bowl", quantity: quantity,
                kcal: 200, localDate: day, loggedAt: "\(day)T00:00:00Z")
    }

    func testRecentRoutineOutranksAnOldFavoriteLoggedOnceToday() {
        let foods = [food("Old favorite", uses: 40), food("New routine", uses: 2)]
        let logs = [log("1", food: "Old favorite", day: "2026-11-24", quantity: 3),
                    log("2", food: "Old favorite", day: "2026-09-25"),
                    log("3", food: "Old favorite", day: "2026-09-25"),
                    log("4", food: "New routine", day: "2026-11-14"),
                    log("5", food: "New routine", day: "2026-11-15")]
        XCTAssertEqual(rank(foods, logs: logs), ["New routine", "Old favorite"])
        XCTAssertEqual(rank(foods, logs: Array(logs.dropLast())), ["Old favorite", "New routine"])
    }

    func testThirtyDayHalfLifeUsesLifetimeCountToBreakTies() {
        let foods = [food("Today", uses: 1), food("Thirty days ago", uses: 2), food("Sixty days ago", uses: 4)]
        let logs = [log("today", food: "Today", day: "2026-11-24")]
            + (1...2).map { log("thirty-\($0)", food: "Thirty days ago", day: "2026-10-25") }
            + (1...4).map { log("sixty-\($0)", food: "Sixty days ago", day: "2026-09-25") }
        XCTAssertEqual(rank(foods, logs: logs), ["Sixty days ago", "Thirty days ago", "Today"])

        let withOlderLifetimeUse = [food("Today", uses: 40), food("Thirty days ago", uses: 30), foods[2]]
        XCTAssertEqual(rank(withOlderLifetimeUse, logs: logs), ["Today", "Thirty days ago", "Sixty days ago"])
    }

    func testRankingWindowExpiresOldLogsAndPreservesTheFallbackOrder() {
        let foods = [food("Unused", uses: 0), food("Expired", uses: 40, lastUsedAt: "2026-08-26T00:00:00Z"),
                     food("At the boundary", uses: 1), food("Hidden", uses: 10, dismissed: true),
                     food("Older favorite", uses: 40, lastUsedAt: "2026-08-25T00:00:00Z")]
        let logs = [log("1", food: "Expired", day: "2026-08-26"),
                    log("2", food: "Expired", day: "2026-08-26"),
                    log("3", food: "At the boundary", day: "2026-08-27"),
                    log("4", food: "Hidden", day: "2026-11-24")]
        XCTAssertEqual(rank(foods, logs: logs), ["At the boundary", "Expired", "Older favorite", "Unused"])
    }
}
