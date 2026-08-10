import XCTest
import SwiftUI
@testable import MiniClockify

final class StopConfirmKeysTests: XCTestCase {
    func testCommandDeleteIsDiscardChord() {
        XCTAssertTrue(StopConfirmKeys.isDiscardChord(character: "\u{7F}", modifiers: .command))
    }

    /// Some event sources deliver backspace as U+0008 rather than U+007F.
    func testCommandBackspaceIsDiscardChord() {
        XCTAssertTrue(StopConfirmKeys.isDiscardChord(character: "\u{8}", modifiers: .command))
    }

    func testExtraModifiersStillMatch() {
        XCTAssertTrue(StopConfirmKeys.isDiscardChord(
            character: "\u{7F}", modifiers: [.command, .shift]))
    }

    /// Bare backspace must not discard — it is too easy to hit by accident.
    func testUnmodifiedDeleteDoesNotMatch() {
        XCTAssertFalse(StopConfirmKeys.isDiscardChord(character: "\u{7F}", modifiers: []))
        XCTAssertFalse(StopConfirmKeys.isDiscardChord(character: "\u{8}", modifiers: .option))
    }

    func testOtherKeysDoNotMatch() {
        XCTAssertFalse(StopConfirmKeys.isDiscardChord(character: "d", modifiers: .command))
        XCTAssertFalse(StopConfirmKeys.isDiscardChord(character: "\r", modifiers: .command))
        XCTAssertFalse(StopConfirmKeys.isDiscardChord(character: "\u{1B}", modifiers: .command))
    }
}
