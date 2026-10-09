import XCTest
@testable import ZeroZeroFood

final class DailyReviewMarkdownTests: XCTestCase {
    func testHeadingsListsAndInlineFormatting() {
        let blocks = DailyReviewMarkdown.blocks("## Overview\n\n**Protein** and *variety*.\n\n- Water: **at least 2 L**\n- Produce: 5+ portions\n\n1. Keep it varied.\n\n[Source](https://example.com)")
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0].headingLevel, 2)
        XCTAssertEqual(String(blocks[0].text.characters), "Overview")
        XCTAssertTrue(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertEqual(blocks[2].listMarker, "•")
        XCTAssertEqual(blocks[3].listMarker, "•")
        XCTAssertEqual(blocks[4].listMarker, "1.")
        XCTAssertEqual(blocks[5].text.runs.first?.link, URL(string: "https://example.com"))
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    func testPlainParagraphsAndUnsupportedLinkSchemes() {
        let blocks = DailyReviewMarkdown.blocks("A plain review.\n\nSee [this](file:///tmp/example).")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(String(blocks[0].text.characters), "A plain review.")
        XCTAssertEqual(String(blocks[1].text.characters), "See this.")
        XCTAssertTrue(blocks[1].text.runs.allSatisfy { $0.link == nil })
    }
}
