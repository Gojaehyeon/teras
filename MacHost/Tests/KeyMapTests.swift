import CoreGraphics
import XCTest
@testable import TerasCore

final class KeyMapTests: XCTestCase {

    func testLetters() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x00), 29, "A")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x0B), 30, "B")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x06), 54, "Z")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x09), 50, "V")
    }

    func testDigits() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x1D), 7, "0")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x12), 8, "1")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x19), 16, "9")
    }

    func testEditingAndNavigation() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x24), 66, "return → ENTER")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x33), 67, "delete → DEL")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x75), 112, "forward delete")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x30), 61, "tab")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x31), 62, "space")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x35), 4, "escape → BACK")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x73), 122, "home → MOVE_HOME")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x77), 123, "end → MOVE_END")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x74), 92, "page up")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x79), 93, "page down")
    }

    func testArrows() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x7E), 19, "up")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x7D), 20, "down")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x7B), 21, "left")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x7C), 22, "right")
    }

    func testFunctionKeys() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x7A), 131, "F1")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x78), 132, "F2")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x6F), 142, "F12")
    }

    func testPunctuation() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x1B), 69, "minus")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x18), 70, "equals")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x21), 71, "[")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x1E), 72, "]")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x2A), 73, "backslash")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x29), 74, "semicolon")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x27), 75, "apostrophe")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x32), 68, "grave")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x2B), 55, "comma")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x2F), 56, "period")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x2C), 76, "slash")
    }

    func testModifiersMapToKeysAndAreRecognised() {
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x38), 59, "left shift")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x37), 117, "left command → META_LEFT")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x3A), 57, "left option → ALT_LEFT")
        XCTAssertEqual(KeyMap.androidKeyCode(forMacKeyCode: 0x3B), 113, "left control → CTRL_LEFT")
        XCTAssertTrue(KeyMap.isModifier(macKeyCode: 0x38))
        XCTAssertFalse(KeyMap.isModifier(macKeyCode: 0x00))
    }

    func testUnmappedKeyCodeReturnsNil() {
        XCTAssertNil(KeyMap.androidKeyCode(forMacKeyCode: 0x6E), "context menu key has no mapping")
    }

    // MARK: - Meta state

    func testMetaStateSetsGenericAndLeftBits() {
        let meta = KeyMap.metaState(from: [.maskShift, .maskCommand])
        XCTAssertEqual(meta & KeyMap.Meta.shiftOn, KeyMap.Meta.shiftOn)
        XCTAssertEqual(meta & KeyMap.Meta.shiftLeftOn, KeyMap.Meta.shiftLeftOn)
        XCTAssertEqual(meta & KeyMap.Meta.metaOn, KeyMap.Meta.metaOn)
        XCTAssertEqual(meta & KeyMap.Meta.metaLeftOn, KeyMap.Meta.metaLeftOn)
        XCTAssertEqual(meta & KeyMap.Meta.altOn, 0)
        XCTAssertEqual(meta & KeyMap.Meta.ctrlOn, 0)
    }

    func testMetaStateForControlAndOption() {
        let meta = KeyMap.metaState(from: [.maskControl, .maskAlternate])
        XCTAssertEqual(meta, KeyMap.Meta.ctrlOn | KeyMap.Meta.ctrlLeftOn | KeyMap.Meta.altOn | KeyMap.Meta.altLeftOn)
    }

    func testMetaStateIsEmptyWithoutModifiers() {
        XCTAssertEqual(KeyMap.metaState(from: []), 0)
    }

    // MARK: - Text fallback

    func testPrintableFallbackAcceptsOrdinaryText() {
        XCTAssertTrue(KeyMap.isPrintableFallback("가"))
        XCTAssertTrue(KeyMap.isPrintableFallback("é"))
        XCTAssertTrue(KeyMap.isPrintableFallback("€"))
        XCTAssertTrue(KeyMap.isPrintableFallback("a"))
    }

    func testPrintableFallbackRejectsControlCharacters() {
        XCTAssertFalse(KeyMap.isPrintableFallback(""))
        XCTAssertFalse(KeyMap.isPrintableFallback("\u{1B}"))
        XCTAssertFalse(KeyMap.isPrintableFallback("\n"))
        XCTAssertFalse(KeyMap.isPrintableFallback("\u{7F}"))
    }
}
