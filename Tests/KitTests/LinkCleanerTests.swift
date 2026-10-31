import XCTest
@testable import Kit

final class LinkCleanerTests: XCTestCase {
    func testRemovesUTMAndKeepsRealParameters() {
        let r = LinkCleaner.clean("https://example.com/a?id=7&utm_source=x&utm_medium=y")
        XCTAssertEqual(r.text, "https://example.com/a?id=7")
        XCTAssertEqual(r.removed, 2)
    }

    func testDropsQuestionMarkWhenNothingLeft() {
        XCTAssertEqual(LinkCleaner.clean("https://example.com/?fbclid=abc").text, "https://example.com/")
    }

    func testHostSpecificRulesOnlyApplyToThatHost() {
        XCTAssertEqual(LinkCleaner.clean("https://youtu.be/xyz?si=123&t=42").text, "https://youtu.be/xyz?t=42")
        XCTAssertEqual(LinkCleaner.clean("https://example.com/?si=123").removed, 0)
    }

    func testCleansLinksInsideProse() {
        let r = LinkCleaner.clean("Read https://a.com/x?gclid=1 and https://b.com/y?utm_campaign=z today.")
        XCTAssertEqual(r.text, "Read https://a.com/x and https://b.com/y today.")
        XCTAssertEqual(r.removed, 2)
    }

    func testLeavesPlainTextAlone() {
        XCTAssertEqual(LinkCleaner.clean("no links here?utm_source=1").removed, 0)
    }
}
