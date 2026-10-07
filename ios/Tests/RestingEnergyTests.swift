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

    func testMaintainPlanHasNoCalorieGap() {
        let profile = FoodProfile(heightCm: 175, weightKg: 80, estimateProfile: "male",
                                  deficitKcal: DeficitLevel.maintain.rawValue, birthYear: 1980)
        XCTAssertEqual(DeficitLevel.maintain.title, "Maintain")
        XCTAssertEqual(profile.target(for: profile.deficitKcal, resting: 1800), 1800)
        XCTAssertEqual(profile.effectiveDeficit(for: profile.deficitKcal, resting: 1800), 0)
    }

    @MainActor
    func testLatestRecordedWeightUpdatesFallbackWithoutReplacingHealthAverage() {
        let health = HealthEnergy()
        var profile = FoodProfile(heightCm: 175, weightKg: 70, estimateProfile: "male",
                                  deficitKcal: 300, birthYear: 1980)
        health.latestWeightKg = 80
        profile.weightKg = 80
        let latestEstimate = profile.restingKcal
        profile.weightKg = 70
        XCTAssertEqual(health.effectiveRestingKcal(for: profile), latestEstimate)
        health.restingAverageKcal = 1900
        XCTAssertEqual(health.effectiveRestingKcal(for: profile), 1900)
        health.restingAverageKcal = nil
        health.latestWeightKg = .nan
        XCTAssertEqual(health.effectiveRestingKcal(for: profile), profile.restingKcal)
    }
}
