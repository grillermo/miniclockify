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

    func testAutocompleteReturnsFirstLongerMatchCaseInsensitive() {
        let input = ["Clockify design", "deploy", "clockify build"]
        XCTAssertEqual(RecentDescriptions.firstAutocomplete(descriptions: input, query: "clo"),
                       "Clockify design")
    }

    func testAutocompleteMatchesMidWordSubstring() {
        let input = ["deploy", "Create billing system", "write docs"]
        XCTAssertEqual(RecentDescriptions.firstAutocomplete(descriptions: input, query: "bill"),
                       "Create billing system")
    }

    func testAutocompletePrefersPrefixOverSubstring() {
        // "billing" (substring in #1) appears before "Bill Ford" (prefix), but a
        // prefix match wins regardless of order.
        let input = ["Create billing system", "Bill Ford"]
        XCTAssertEqual(RecentDescriptions.firstAutocomplete(descriptions: input, query: "bill"),
                       "Bill Ford")
    }

    func testAutocompleteNilOnEmptyOrNoMatch() {
        let input = ["deploy", "write docs"]
        XCTAssertNil(RecentDescriptions.firstAutocomplete(descriptions: input, query: ""))
        XCTAssertNil(RecentDescriptions.firstAutocomplete(descriptions: input, query: "xyz"))
    }

    func testAutocompleteNilOnExactHit() {
        XCTAssertNil(RecentDescriptions.firstAutocomplete(descriptions: ["deploy"], query: "deploy"))
    }
}
