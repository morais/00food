import XCTest
@testable import ZeroZeroFood

final class EstimationMealTimeTests: XCTestCase {
    private func estimation(loggedAt: String? = nil) -> PendingEstimation {
        PendingEstimation(id: "estimate", description: "Soup", hasPhoto: false, state: "proposed",
            proposedName: "Soup", proposedServing: "1 bowl", proposedKcal: 300, agentNote: nil,
            localDate: "2026-10-17", createdAt: "2026-10-18T12:30:00Z", updatedAt: "2026-10-18T19:00:00Z",
            loggedAt: loggedAt)
    }

    func testMealTimeSurvivesOfflineRestartAndLaterProposal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = estimation(loggedAt: "2026-10-17T18:30:00-04:00")
        let state = OfflineFoodState(snapshot: FoodSnapshot(foods: [], logs: [], estimations: [requested]),
                                     operations: [.estimate(requested, nil)])
        try OfflineFoodDisk.save(state, for: "meal-time-test", in: directory)
        let restored = try XCTUnwrap(OfflineFoodDisk.load(for: "meal-time-test", in: directory))
        guard case .estimate(var queued, _) = restored.operations.first else { return XCTFail("Missing estimate") }
        queued.updatedAt = "2026-10-19T20:00:00Z"
        XCTAssertEqual(queued.mealTimestamp, FoodDates.parseTimestamp("2026-10-17T22:30:00Z"))
        XCTAssertEqual(restored.snapshot.estimations.first?.loggedAt, requested.loggedAt)
    }

    func testOlderRequestUsesCreationClockOnChosenDayNotProposalTime() throws {
        let request = estimation()
        let timestamp = try XCTUnwrap(request.mealTimestamp)
        let created = try XCTUnwrap(FoodDates.parseTimestamp(request.createdAt))
        let calendar = Calendar.current
        XCTAssertEqual(FoodDates.localDate(for: timestamp), request.localDate)
        XCTAssertEqual(calendar.component(.hour, from: timestamp), calendar.component(.hour, from: created))
        XCTAssertEqual(calendar.component(.minute, from: timestamp), calendar.component(.minute, from: created))
        XCTAssertNotEqual(timestamp, FoodDates.parseTimestamp(request.updatedAt))
    }

    func testOlderPendingRequestStillDecodesWithoutMealTimeField() throws {
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(estimation())) as? [String: Any])
        data.removeValue(forKey: "loggedAt")
        let restored = try JSONDecoder().decode(PendingEstimation.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(restored.loggedAt)
        XCTAssertNotNil(restored.mealTimestamp)
    }
}
