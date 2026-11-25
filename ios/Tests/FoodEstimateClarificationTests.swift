import XCTest
@testable import ZeroZeroFood

final class FoodEstimateClarificationTests: XCTestCase {
    func testExactNameTakesPrecedenceOverPartialDescription() {
        let open = [estimate("chicken", "Chicken burrito with salsa"), estimate("bean", "Lunch", proposedName: "Burrito")]

        XCTAssertEqual(ClarifyFoodEstimateIntent.matches(in: open, name: "burrito").map(\.id), ["bean"])
        XCTAssertEqual(ClarifyFoodEstimateIntent.matches(in: open, name: "chicken burrito").map(\.id), ["chicken"])
    }

    func testOriginalDescriptionStillMatchesAfterProposal() {
        let open = [estimate("lunch", "Cheese toast for lunch", proposedName: "Grilled cheese")]

        XCTAssertEqual(ClarifyFoodEstimateIntent.matches(in: open, name: "cheese toast").map(\.id), ["lunch"])
        XCTAssertTrue(ClarifyFoodEstimateIntent.matches(in: open, name: "soup").isEmpty)
    }

    func testAmbiguousNameDoesNotChooseAnEstimate() {
        let open = [estimate("lunch", "Chicken burrito"), estimate("dinner", "Bean burrito")]

        XCTAssertEqual(ClarifyFoodEstimateIntent.matches(in: open, name: "burrito").map(\.id), ["lunch", "dinner"])
    }

    private func estimate(_ id: String, _ description: String, proposedName: String? = nil) -> PendingEstimation {
        PendingEstimation(id: id, description: description, hasPhoto: false,
            state: proposedName == nil ? "pending" : "proposed", proposedName: proposedName,
            proposedServing: nil, proposedKcal: nil, agentNote: nil, localDate: "2026-11-25",
            createdAt: "2026-11-25T12:00:00Z", updatedAt: "2026-11-25T12:00:00Z")
    }
}
