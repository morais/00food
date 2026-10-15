import XCTest
@testable import ZeroZeroFood

final class DailyReviewInstructionsTests: XCTestCase {
    func testLongInstructionsRespectAPILimitWithoutSplittingCharacters() {
        let prefix = String(repeating: "a", count: 1_998) + "e\u{301}"
        let clipped = DailyReviewInstructions.limited(prefix + "😀 rest")
        XCTAssertEqual(clipped, prefix)
        XCTAssertEqual(clipped.utf16.count, 2_000)
        XCTAssertEqual(DailyReviewInstructions.limited("Focus on protein.\nKeep it brief."),
                       "Focus on protein.\nKeep it brief.")
    }

    func testLegacyOfflineRequestHasNoInstructions() throws {
        let data = Data(#"{"id":"old","localDate":"2026-10-14","timeZone":"UTC","healthDays":[]}"#.utf8)
        let request = try JSONDecoder().decode(DailyFeedbackUpload.self, from: data)
        XCTAssertNil(request.userInstructions)
    }
}
