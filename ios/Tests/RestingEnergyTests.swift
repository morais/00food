import XCTest
@testable import ZeroZeroFood

final class RestingEnergyTests: XCTestCase {
    func testFallbackUsesReferenceAge35AndMigratesOldProfile() throws {
        let raw = Data("""
        {"heightCm":175,"weightKg":80,"estimateProfile":"male","deficitKcal":300,"birthYear":1950}
        """.utf8)
        let profile = try JSONDecoder().decode(FoodProfile.self, from: raw)
        XCTAssertEqual(profile.restingKcal, 1724)
        XCTAssertEqual(profile.deficitPercent, 10)
        XCTAssertEqual(profile.budget(active: 776).allowanceKcal, 2250)
    }

    func testAllPacesApplyToRestingPlusExercise() {
        let profile = FoodProfile(heightCm: 175, weightKg: 80, estimateProfile: "male", deficitPercent: 20)
        for (pace, allowance) in [(DeficitLevel.maintain, 2500), (.gentle, 2250), (.balanced, 2125), (.faster, 2000)] {
            let budget = profile.budget(resting: 1800, active: 700, deficitPercent: pace.rawValue)
            XCTAssertEqual(budget.tdeeKcal, 2500)
            XCTAssertEqual(budget.allowanceKcal, allowance)
            XCTAssertEqual(budget.gapKcal, 2500 - allowance)
        }
        XCTAssertEqual(profile.budget(resting: 1800, active: 800).allowanceKcal, 2080)
        XCTAssertEqual(DeficitLevel.balanced.title, "Balanced")
    }

    func testBudgetScalesWithSizeWithoutLegacyFixedFloor() {
        let profile = FoodProfile(heightCm: 160, weightKg: 55, estimateProfile: "female", deficitPercent: 20)
        XCTAssertEqual(profile.budget(resting: 1400, active: 0).allowanceKcal, 1120)
        XCTAssertEqual(profile.budget(resting: 2000, active: 1000).allowanceKcal, 2400)
    }

    func testBudgetUsesCompletedHealthDaysWhenMostOfWeekIsAvailable() {
        let summary = RestingEnergySummary(completedDayTotals: [1700, 1800, 1750, 1850, 1900, 0, 0])
        XCTAssertEqual(summary.daysUsed, 5)
        XCTAssertEqual(summary.averageKcal, 1800)
        let profile = FoodProfile(heightCm: 175, weightKg: 80, estimateProfile: "male", deficitPercent: 15)
        XCTAssertEqual(profile.budget(resting: summary.averageKcal, active: 700).allowanceKcal, 2125)
        XCTAssertNil(RestingEnergySummary(completedDayTotals: [1700, 1800, 1750, 0]).averageKcal)
    }

    func testLegacyOfflineProfileSavesMigrateWithoutLosingTheQueue() throws {
        for (old, percent) in [(0, 0), (300, 10), (450, 15), (600, 20)] {
            let raw = Data("""
            {"saveProfile":{"_0":{"heightCm":175,"weightKg":80,"estimateProfile":"male","deficitKcal":\(old)}}}
            """.utf8)
            let operation = try JSONDecoder().decode(OfflineFoodOperation.self, from: raw)
            guard case .saveProfile(let profile) = operation else { return XCTFail("Lost profile save") }
            XCTAssertEqual(profile.deficitPercent, percent)
            let encoded = String(decoding: try JSONEncoder().encode(operation), as: UTF8.self)
            XCTAssertTrue(encoded.contains("deficitPercent"))
            XCTAssertFalse(encoded.contains("deficitKcal"))
        }
        let new = Data("""
        {"heightCm":175,"weightKg":80,"estimateProfile":"male","deficitKcal":600,"deficitPercent":10}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FoodProfile.self, from: new).deficitPercent, 10)
    }

    func testForecastExcludesTodayOldAndUnpairedHealthDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        func point(_ offset: Int, _ value: Double) -> HealthMeasurePoint {
            HealthMeasurePoint(date: calendar.date(byAdding: .day, value: offset, to: now)!, value: value)
        }
        let summary = TDEESummary(resting: [point(-1, 1800), point(-2, 1900), point(-3, 1700), point(0, 900), point(-8, 5000)],
                                  active: [point(-1, 700), point(-2, 800), point(0, 400), point(-8, 3000)], now: now, calendar: calendar)
        XCTAssertEqual(summary.daysUsed, 2)
        XCTAssertEqual(summary.averageKcal, 2600)
        XCTAssertNil(TDEESummary(resting: [], active: [], now: now).averageKcal)
    }

    @MainActor
    func testTodayHistoryAndForecastUseAppropriateHealthEnergy() {
        let health = HealthEnergy()
        let profile = FoodProfile(heightCm: 175, weightKg: 70, estimateProfile: "male", deficitPercent: 20)
        health.latestWeightKg = 80
        XCTAssertEqual(health.effectiveRestingKcal(for: profile), 1724)
        health.restingAverageKcal = 1800
        health.activeKcal = 700
        health.completedAverageTDEEKcal = 2600
        XCTAssertEqual(health.dailyBudget(for: profile).allowanceKcal, 2000)
        XCTAssertEqual(health.representativeBudget(for: profile).gapKcal, 520)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        health.restingHistory = [.init(date: yesterday, value: 1900)]
        health.activeHistory = [.init(date: yesterday, value: 800)]
        XCTAssertEqual(health.budget(for: profile, on: yesterday).allowanceKcal, 2160)
        health.restingHistory = []
        XCTAssertEqual(health.budget(for: profile, on: yesterday).allowanceKcal, 2080)
        health.restingAverageKcal = nil
        health.latestWeightKg = .nan
        XCTAssertEqual(health.effectiveRestingKcal(for: profile), profile.restingKcal)
    }

    func testWidgetUsesFullBudgetAndDecodesLegacyCache() throws {
        let raw = Data("""
        {"localDate":"2026-10-09","targetKcal":1500,"activeKcal":500,"consumedKcal":800,"pendingCount":0,"startMinutes":420,"endMinutes":1380}
        """.utf8)
        var snapshot = try JSONDecoder().decode(FoodWidgetSnapshot.self, from: raw)
        XCTAssertEqual(snapshot.remainingKcal, 1200)
        snapshot.budgetKcal = 1700
        XCTAssertEqual(snapshot.allowanceKcal, 1700)
        XCTAssertEqual(snapshot.remainingKcal, 900)
    }
}
