import XCTest
@testable import MiniClockify

final class RecentDescriptionsTests: XCTestCase {
    func testDedupKeepsMostRecentFirst() {
        let input = ["fix bug", "write docs", "fix bug", "deploy"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""),
                       ["fix bug", "write docs", "deploy"])
    }

    func testDedupIsCaseInsensitiveKeepingFirstCasing() {
        let input = ["Fix Bug", "fix bug", "deploy"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""),
                       ["Fix Bug", "deploy"])
    }

    func testSubstringCaseInsensitive() {
        let input = ["Fix Bug", "write docs", "DEPLOY"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: "o"),
                       ["write docs", "DEPLOY"])
    }

    func testEmptyDescriptionsDropped() {
        let input = ["", "  ", "real"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""), ["real"])
    }

    func testDedupTrimsWhitespaceBeforeComparingAndKeeping() {
        let input = ["fix bug", "  fix bug  ", "deploy"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""),
                       ["fix bug", "deploy"])
    }

    func testPrefixMatchReturnsFirstLongerMatchCaseInsensitive() {
        let input = ["Clockify design", "deploy", "clockify build"]
        XCTAssertEqual(RecentDescriptions.firstPrefixMatch(descriptions: input, query: "clo"),
                       "Clockify design")
    }

    func testPrefixMatchNilOnEmptyOrNoMatch() {
        let input = ["deploy", "write docs"]
        XCTAssertNil(RecentDescriptions.firstPrefixMatch(descriptions: input, query: ""))
        XCTAssertNil(RecentDescriptions.firstPrefixMatch(descriptions: input, query: "xyz"))
    }

    func testPrefixMatchNilOnExactHit() {
        let input = ["deploy", "deployment"]
        // "deploy" matches "deploy" exactly (nothing to complete) but "deployment"
        // is longer, so it is offered instead.
        XCTAssertEqual(RecentDescriptions.firstPrefixMatch(descriptions: input, query: "deploy"),
                       "deployment")
        XCTAssertNil(RecentDescriptions.firstPrefixMatch(descriptions: ["deploy"], query: "deploy"))
    }
}
