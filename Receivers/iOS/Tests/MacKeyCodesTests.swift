import XCTest
import UIKit
@testable import TandemReceiver

final class MacKeyCodesTests: XCTestCase {

    func testLetterAndDigitMapping() {
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardA), 0)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardZ), 6)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardQ), 12)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboard1), 18)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboard5), 23)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboard0), 29)
    }

    func testEditingAndNavigationMapping() {
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardReturnOrEnter), 36)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardTab), 48)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardSpacebar), 49)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardDeleteOrBackspace), 51)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardEscape), 53)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardLeftArrow), 123)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardRightArrow), 124)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardDownArrow), 125)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardUpArrow), 126)
    }

    func testModifierMapping() {
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardLeftGUI), 55)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardLeftShift), 56)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardLeftAlt), 58)
        XCTAssertEqual(MacKeyCodes.code(for: .keyboardLeftControl), 59)
    }

    func testUnmappedKeyHasNoCode() {
        XCTAssertNil(MacKeyCodes.code(for: .keyboardPrintScreen))
        XCTAssertNil(MacKeyCodes.code(for: .keyboardPause))
    }

    func testModifierNamesUseProtocolSpelling() {
        XCTAssertEqual(MacKeyCodes.modifierNames([]), [])
        XCTAssertEqual(MacKeyCodes.modifierNames([.command]), ["cmd"])
        XCTAssertEqual(MacKeyCodes.modifierNames([.command, .shift, .alternate, .control]),
                       ["cmd", "shift", "alt", "ctrl"])
    }

    func testKeyCommandInputsCoverTheSystemClaimedKeys() {
        XCTAssertEqual(MacKeyCodes.keyCommandUsages.count, MacKeyCodes.keyCommandInputs.count)
        XCTAssertTrue(MacKeyCodes.keyCommandUsages.contains(UIKeyboardHIDUsage.keyboardEscape.rawValue))
        XCTAssertTrue(MacKeyCodes.keyCommandUsages.contains(UIKeyboardHIDUsage.keyboardTab.rawValue))
        XCTAssertTrue(MacKeyCodes.keyCommandUsages.contains(UIKeyboardHIDUsage.keyboardUpArrow.rawValue))
        XCTAssertEqual(MacKeyCodes.usage(forKeyCommandInput: UIKeyCommand.inputLeftArrow), .keyboardLeftArrow)
        XCTAssertNil(MacKeyCodes.usage(forKeyCommandInput: "z"))
    }
}
