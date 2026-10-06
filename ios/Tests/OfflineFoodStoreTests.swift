import XCTest
import UIKit
@testable import ZeroZeroFood

final class OfflineFoodStoreTests: XCTestCase {
    func testPhotoControlSymbolIsAvailable() {
        XCTAssertNotNil(UIImage(systemName: "fork.knife.circle.fill"))
    }

    func testQueuedPhotoAndLogSurviveRestartInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let food = FoodItem(id: UUID().uuidString.lowercased(), name: "Rice bowl", serving: "1 bowl",
                            kcal: 540, source: "manual", useCount: 1, lastUsedAt: "2026-10-04T18:00:00Z",
                            dismissedAt: nil, createdAt: "2026-10-04T18:00:00Z", updatedAt: "2026-10-04T18:00:00Z")
        let log = FoodLog(id: UUID().uuidString.lowercased(), foodId: food.id, foodName: food.name,
                          serving: food.serving, quantity: 1, kcal: 540, localDate: "2026-10-04",
                          loggedAt: "2026-10-04T18:00:00Z")
        let estimation = PendingEstimation(id: UUID().uuidString.lowercased(), description: "Lunch",
                                           hasPhoto: true, state: "uploading", proposedName: nil,
                                           proposedServing: nil, proposedKcal: nil, agentNote: nil,
                                           localDate: "2026-10-04", createdAt: log.loggedAt,
                                           updatedAt: log.loggedAt)
        let photo = Data([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9])
        let state = OfflineFoodState(
            snapshot: FoodSnapshot(startedAt: log.loggedAt, profile: nil,
                                   foods: [food], logs: [log], estimations: [estimation]),
            operations: [.createFood(food), .log(log), .estimate(estimation, photo),
                         .clarifyEstimate(estimation.id, "clarification-id", "There is yogurt underneath")])

        try OfflineFoodDisk.save(state, for: "account A token", in: directory)
        XCTAssertNil(try OfflineFoodDisk.load(for: "account B token", in: directory))
        let restored = try XCTUnwrap(OfflineFoodDisk.load(for: "account A token", in: directory))
        XCTAssertEqual(restored.snapshot.logs.first?.loggedAt, log.loggedAt)
        XCTAssertEqual(restored.operations.count, 4)
        if case .createFood(let restoredFood) = restored.operations[0] {
            XCTAssertEqual(restoredFood.id, food.id)
        } else { XCTFail("Food creation must replay first") }
        if case .log(let restoredLog) = restored.operations[1] {
            XCTAssertEqual(restoredLog.id, log.id)
        } else { XCTFail("Log must replay after food creation") }
        if case .estimate(let restoredEstimate, let restoredPhoto) = restored.operations[2] {
            XCTAssertEqual(restoredEstimate.description, "Lunch")
            XCTAssertEqual(restoredPhoto, photo)
        } else { XCTFail("Photo and description must replay together") }
        if case .clarifyEstimate(let id, let clarificationId, let text) = restored.operations[3] {
            XCTAssertEqual(id, estimation.id)
            XCTAssertEqual(clarificationId, "clarification-id")
            XCTAssertEqual(text, "There is yogurt underneath")
        } else { XCTFail("Clarification must replay after the estimate") }
        try OfflineFoodDisk.clear(for: "account A token", in: directory)
        XCTAssertNil(try OfflineFoodDisk.load(for: "account A token", in: directory))
    }
}
