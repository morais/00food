import XCTest
@testable import ZeroZeroFood

final class MeasurementUnitsTests: XCTestCase {
    func testFollowsMeasurementSettingAndDeveloperCanOverrideIt() {
        XCTAssertEqual(MeasurementPreference.system.resolved(measurementSystem: .metric), .metric)
        XCTAssertEqual(MeasurementPreference.system.resolved(measurementSystem: .us), .us)
        XCTAssertEqual(MeasurementPreference.system.resolved(measurementSystem: .uk), .uk)
        XCTAssertEqual(MeasurementPreference.us.resolved(measurementSystem: .metric), .us)
        XCTAssertEqual(MeasurementPreference.metric.resolved(measurementSystem: .us), .metric)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("invalid", forKey: MeasurementPreference.key)
        XCTAssertEqual(MeasurementPreference.current(defaults: defaults, locale: Locale(identifier: "en_US")), .us)
        defaults.set("metric", forKey: MeasurementPreference.key)
        XCTAssertEqual(MeasurementPreference.current(defaults: defaults, locale: Locale(identifier: "en_US")), .metric)
    }

    func testWeightAndHeightRoundTripWithoutChangingMetricData() {
        for units in FoodUnitSystem.allCases {
            let pounds = units.weightValue(85)
            XCTAssertEqual(units.kilograms(pounds), 85, accuracy: 1e-9)
            let profile = FoodProfile(heightCm: 175, weightKg: 85, estimateProfile: "male", deficitPercent: 15)
            _ = units.weight(profile.weightKg)
            _ = units.weightRange(ProgressProjection.healthyWeightRange(for: profile.heightCm))
            XCTAssertEqual(profile.weightKg, 85)
            XCTAssertEqual(profile.heightCm, 175)
            XCTAssertEqual(profile.budget(resting: 1800, active: 500).allowanceKcal, 1955)
        }
        XCTAssertEqual(FoodUnitSystem.us.weightValue(85), 187.392922857, accuracy: 0.000001)
        XCTAssertEqual(FoodUnitSystem.us.centimeters(feet: 5, inches: 10), 177.8, accuracy: 1e-9)
        let parts = FoodUnitSystem.us.heightParts(182.8799)
        XCTAssertEqual(parts.feet, 6)
        XCTAssertEqual(parts.inches, 0, accuracy: 1e-9, "Rounded height must not show 5 ft 12 in")
    }

    func testUSAndImperialFluidOuncesAreDifferentButLogSameWater() {
        XCTAssertEqual(FoodUnitSystem.us.waterValue(250), 8.4535, accuracy: 0.0001)
        XCTAssertEqual(FoodUnitSystem.uk.waterValue(250), 8.7988, accuracy: 0.0001)
        for units in FoodUnitSystem.allCases {
            XCTAssertEqual(units.milliliters(units.waterValue(250)), 250, accuracy: 1e-9)
            XCTAssertEqual(units.milliliters(units.waterValue(2000)), 2000, accuracy: 1e-9)
        }
    }

    func testWatchPreferenceSurvivesSnapshotAndLegacySnapshotsRemainReadable() throws {
        var snapshot = WatchSnapshot()
        snapshot.measurementSystem = "us"
        snapshot.waterMl = 2000
        snapshot.budgetKcal = 1955
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(WatchSnapshot.self, from: data)
        XCTAssertEqual(restored.measurementSystem, "us")
        XCTAssertEqual(restored.waterMl, 2000)
        XCTAssertEqual(restored.allowanceKcal, 1955)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "measurementSystem")
        let old = try JSONDecoder().decode(WatchSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.measurementSystem)
        XCTAssertEqual(old.waterMl, 2000)
    }
}
