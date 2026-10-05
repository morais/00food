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

}
