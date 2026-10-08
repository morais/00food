import XCTest
@testable import ZeroZeroFood

final class HealthDayCacheTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var cache: HealthDayCache!

    override func setUp() {
        super.setUp()
        suite = "HealthDayCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        cache = HealthDayCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        cache = nil
        defaults = nil
        super.tearDown()
    }

    func testReadingsSurviveRelaunchOnTheSameDay() throws {
        let now = Date()
        var snapshot = HealthDaySnapshot(day: .init(date: now))
        snapshot.allowance = .init(activeKcal: 954, restingAverageKcal: 1768, restingDaysUsed: 7)
        snapshot.waterMl = 1500
        cache.save(snapshot, on: now)

        let reopened = HealthDayCache(defaults: defaults)
        let restored = try XCTUnwrap(reopened.load(on: now))
        XCTAssertEqual(restored.allowance?.activeKcal, 954)
        XCTAssertEqual(restored.allowance?.restingAverageKcal, 1768)
        XCTAssertEqual(restored.waterMl, 1500)
    }

    func testYesterdayAndAnotherTimeZoneCannotSupplyTodaysValues() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon)!
        var snapshot = HealthDaySnapshot(day: .init(date: noon, calendar: calendar))
        snapshot.waterMl = 2000
        cache.save(snapshot, on: noon, calendar: calendar)
        XCTAssertNil(cache.load(on: tomorrow, calendar: calendar))

        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(cache.load(on: noon, calendar: calendar))
    }

    func testAnOldCompletionCannotReplaceTheNewDaysCache() throws {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        var current = HealthDaySnapshot(day: .init(date: tomorrow))
        current.waterMl = 250
        cache.save(current, on: tomorrow)
        var old = HealthDaySnapshot(day: .init(date: now))
        old.waterMl = 2000
        cache.save(old, on: tomorrow)
        XCTAssertEqual(try XCTUnwrap(cache.load(on: tomorrow)).waterMl, 250)
    }

    func testFreshZeroReadingsReplaceTheCache() throws {
        var snapshot = HealthDaySnapshot()
        snapshot.waterMl = 1500
        cache.save(snapshot)
        snapshot.waterMl = 0
        snapshot.allowance = .init(activeKcal: 0, restingAverageKcal: nil, restingDaysUsed: 0)
        cache.save(snapshot)
        let fresh = try XCTUnwrap(cache.load())
        XCTAssertEqual(fresh.waterMl, 0)
        XCTAssertEqual(fresh.allowance?.activeKcal, 0)
        XCTAssertNil(fresh.allowance?.restingAverageKcal)
    }

    @MainActor
    func testHealthStartsWithTheEntireCachedBudgetAndWater() {
        var snapshot = HealthDaySnapshot()
        snapshot.allowance = .init(activeKcal: 954, restingAverageKcal: 1768, restingDaysUsed: 7)
        snapshot.waterMl = 1500
        snapshot.weightKg = 82
        snapshot.weightDate = Date()
        snapshot.bodyFatPercent = 27
        cache.save(snapshot)

        let health = HealthEnergy(dayCache: cache)
        XCTAssertEqual(health.activeKcal, 954)
        XCTAssertEqual(health.restingAverageKcal, 1768)
        XCTAssertEqual(health.restingDaysUsed, 7)
        XCTAssertEqual(health.waterMlToday, 1500)
        XCTAssertEqual(health.latestWeightKg, 82)
        XCTAssertEqual(health.latestBodyFatPercent, 27)
        XCTAssertTrue(health.hasLoadedAllowance)
        XCTAssertTrue(health.allowanceIsReady)

        // Foreground/day-change handlers expire the display before waiting for
        // either the server or Health, even when this process stayed alive.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        health.resetReadingsForNewDay(on: tomorrow)
        XCTAssertEqual(health.activeKcal, 0)
        XCTAssertEqual(health.waterMlToday, 0)
        XCTAssertNil(health.restingAverageKcal)
        XCTAssertNil(health.latestWeightKg)
        XCTAssertFalse(health.hasLoadedAllowance)
    }
}
