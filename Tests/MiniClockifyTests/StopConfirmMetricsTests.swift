import XCTest
import AppKit
@testable import MiniClockify

final class StopConfirmMetricsTests: XCTestCase {
    private let width: CGFloat = 460
    private let maxHeight: CGFloat = 700

    private func height(_ description: String) -> CGFloat {
        StopConfirmMetrics.panelHeight(
            description: description, width: width, maxHeight: maxHeight)
    }

    /// A short title needs no more room than the fixed 120pt panel this replaced.
    func testShortDescriptionStaysCompact() {
        XCTAssertLessThanOrEqual(height("Standup"), 130)
    }

    /// The regression that started this: a title too long for one line at 460pt has
    /// to make the panel taller, not get clipped.
    func testLongDescriptionGrowsPanel() {
        let long = "(DC) Make the spend-cap threshold agree across Rails, "
            + "datacenters-ai and ui-kit-themes"
        XCTAssertGreaterThan(height(long), height("Standup"))
    }

    /// Growth tracks the number of wrapped lines, so more text is never shorter.
    func testHeightIsMonotonicInLength() {
        let one = height("Fix the thing")
        let many = height(String(repeating: "Fix the thing. ", count: 12))
        XCTAssertGreaterThan(many, one)
    }

    /// However pathological the title, the panel must stay on screen.
    func testHeightIsCapped() {
        XCTAssertEqual(height(String(repeating: "word ", count: 4000)), maxHeight)
    }

    /// An empty description falls back to the placeholder, so it still gets a line.
    func testEmptyDescriptionMeasuresPlaceholder() {
        XCTAssertEqual(height(""), height(StopConfirmMetrics.placeholder))
        XCTAssertGreaterThan(height(""), StopConfirmMetrics.chromeHeight)
    }
}
