import XCTest
@testable import ZeroZeroFood

final class RestingEnergyTests: XCTestCase {
    func testBudgetUsesCompletedHealthDaysWhenMostOfWeekIsAvailable() {
        let summary = RestingEnergySummary(completedDayTotals: [1700, 1800, 1750, 1850, 1900, 0, 0])
        XCTAssertEqual(summary.daysUsed, 5)
        XCTAssertEqual(summary.averageKcal, 1800)

        let profile = FoodProfile(heightCm: 175, weightKg: 80, estimateProfile: "male",
                                  deficitKcal: 450, birthYear: 1980)
        XCTAssertEqual(profile.target(for: 450, resting: summary.averageKcal), 1350)
        XCTAssertEqual(profile.effectiveDeficit(for: 600, resting: summary.averageKcal), 600)
    }

    func testMissingHealthDaysKeepDetailsEstimateAndFoodFloor() {
        let summary = RestingEnergySummary(completedDayTotals: [1700, 1800, 1750, 0])
        XCTAssertEqual(summary.daysUsed, 3)
        XCTAssertNil(summary.averageKcal)

        let profile = FoodProfile(heightCm: 160, weightKg: 55, estimateProfile: "female",
                                  deficitKcal: 600, birthYear: 1980)
        XCTAssertEqual(profile.target(for: 600, resting: summary.averageKcal), 1200)
        XCTAssertEqual(profile.effectiveDeficit(for: 600, resting: 1600), 400)
    }
}
