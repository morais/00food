import XCTest
@testable import ZeroZeroFood

final class DietaryExportTests: XCTestCase {
    func testDeniedPermissionDoesNotEnrollAndFirstGrantSkipsOlderLogs() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(DietaryExportState.enrolling(existing: nil, authorized: false, now: now))
        let state = try XCTUnwrap(DietaryExportState.enrolling(existing: nil, authorized: true, now: now))
        XCTAssertFalse(state.shouldExport(log(at: now.addingTimeInterval(-60))))
        XCTAssertTrue(state.shouldExport(log(at: now.addingTimeInterval(60))))
    }

    func testUpgradeAndReauthorizationPreserveStartDateAndReceipts() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var state = DietaryExportState(enabledAt: now)
        let food = log(at: now.addingTimeInterval(60))
        state.exported[food.id] = food.localDate
        let persisted = try JSONDecoder().decode(DietaryExportState.self, from: JSONEncoder().encode(state))
        let denied = try XCTUnwrap(DietaryExportState.enrolling(existing: persisted, authorized: false))
        let restored = try XCTUnwrap(DietaryExportState.enrolling(existing: denied, authorized: true,
                                                                 now: now.addingTimeInterval(86400)))
        XCTAssertEqual(restored.enabledAt, now)
        XCTAssertEqual(restored.exported, state.exported)
        XCTAssertFalse(restored.shouldExport(food), "Reauthorization must not duplicate an exported log")
    }

    func testNewBackdatedMealIsExportedUsingItsCreationTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let state = DietaryExportState(enabledAt: now.addingTimeInterval(-60))
        var meal = log(at: now.addingTimeInterval(-86400))
        XCTAssertFalse(state.shouldExport(meal))
        meal.createdAt = ISO8601DateFormatter().string(from: now)
        XCTAssertTrue(state.shouldExport(meal), "A new entry for yesterday is not an old log to skip")
    }

    private func log(at date: Date) -> FoodLog {
        FoodLog(id: "food-log", foodId: "food", foodName: "Yogurt", serving: "1 bowl", quantity: 1,
                kcal: 200, localDate: FoodDates.localDate(for: date),
                loggedAt: ISO8601DateFormatter().string(from: date))
    }
}
