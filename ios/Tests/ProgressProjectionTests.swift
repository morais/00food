import XCTest
@testable import ZeroZeroFood

final class ProgressProjectionTests: XCTestCase {
    func testBodyFatProjectionTreatsWeightLostAsFat() {
        // 80 kg at 25% fat starts with 20 kg of fat. After losing 5 kg of fat,
        // 15 kg of fat remains in a 75 kg body: 20%.
        XCTAssertEqual(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 75), 20, accuracy: 0.001)
        XCTAssertEqual(ProgressProjection.bodyFatPercent(startWeightKg: 80,
                                                           startBodyFatPercent: 25,
                                                           projectedWeightKg: 80), 25, accuracy: 0.001)
    }

    func testOnlyCrossedACEBoundariesAreAddedForEachProfile() {
        let male = ProgressProjection.visibleACEBoundaries(for: "male", projectedPercentages: [28, 16])
        XCTAssertEqual(male.map(\.percentage), [25, 18])
        let female = ProgressProjection.visibleACEBoundaries(for: "female", projectedPercentages: [29, 19])
        XCTAssertEqual(female.map(\.percentage), [32, 25, 21])
        XCTAssertEqual(ProgressProjection.visibleACEBoundaries(for: "neutral", projectedPercentages: [29, 19]), [])
        XCTAssertEqual(ProgressProjection.visibleACEBoundaries(for: "male", projectedPercentages: []),
                       [ACEBodyFatBoundary(category: "Obesity", percentage: 25, isObesity: true)])
    }

}
