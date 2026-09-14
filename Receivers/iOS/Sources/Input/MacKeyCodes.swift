import Foundation
import UIKit

/// Maps iOS HID usages to macOS virtual key codes (`kVK_*` from
/// Carbon's `Events.h`). The host injects `CGEvent`s with these, so getting
/// them right is what makes a hardware keyboard feel native.
///
/// Keys with no entry are sent as `keyCode 0` plus `text`, which the host
/// turns into a unicode key event (PROTOCOL §6.3).
enum MacKeyCodes {

    /// keyCode 0 is a real key (`A`) so callers must use `code(for:)`'s
    /// optionality rather than comparing against zero.
    static let unknown = 0

    static func code(for usage: UIKeyboardHIDUsage) -> Int? {
        table[usage.rawValue]
    }

    static func modifierNames(_ flags: UIKeyModifierFlags) -> [String] {
        var mods: [String] = []
        if flags.contains(.command) { mods.append("cmd") }
        if flags.contains(.shift) { mods.append("shift") }
        if flags.contains(.alternate) { mods.append("alt") }
        if flags.contains(.control) { mods.append("ctrl") }
        return mods
    }

    /// Keys iOS would otherwise consume (focus movement, dismissal). They are
    /// claimed with `UIKeyCommand` and skipped in `pressesBegan`.
    static let keyCommandInputs: [String] = [
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow,
        UIKeyCommand.inputEscape,
        "\t",
    ]

    static func usage(forKeyCommandInput input: String) -> UIKeyboardHIDUsage? {
        switch input {
        case UIKeyCommand.inputUpArrow: return .keyboardUpArrow
        case UIKeyCommand.inputDownArrow: return .keyboardDownArrow
        case UIKeyCommand.inputLeftArrow: return .keyboardLeftArrow
        case UIKeyCommand.inputRightArrow: return .keyboardRightArrow
        case UIKeyCommand.inputEscape: return .keyboardEscape
        case "\t": return .keyboardTab
        default: return nil
        }
    }

    static let keyCommandUsages: Set<Int> = Set(keyCommandInputs.compactMap { usage(forKeyCommandInput: $0)?.rawValue })

    private static let table: [Int: Int] = {
        var map: [Int: Int] = [:]
        func put(_ usage: UIKeyboardHIDUsage, _ code: Int) { map[usage.rawValue] = code }

        // Letters
        put(.keyboardA, 0);  put(.keyboardB, 11); put(.keyboardC, 8);  put(.keyboardD, 2)
        put(.keyboardE, 14); put(.keyboardF, 3);  put(.keyboardG, 5);  put(.keyboardH, 4)
        put(.keyboardI, 34); put(.keyboardJ, 38); put(.keyboardK, 40); put(.keyboardL, 37)
        put(.keyboardM, 46); put(.keyboardN, 45); put(.keyboardO, 31); put(.keyboardP, 35)
        put(.keyboardQ, 12); put(.keyboardR, 15); put(.keyboardS, 1);  put(.keyboardT, 17)
        put(.keyboardU, 32); put(.keyboardV, 9);  put(.keyboardW, 13); put(.keyboardX, 7)
        put(.keyboardY, 16); put(.keyboardZ, 6)

        // Digits (top row)
        put(.keyboard1, 18); put(.keyboard2, 19); put(.keyboard3, 20); put(.keyboard4, 21)
        put(.keyboard5, 23); put(.keyboard6, 22); put(.keyboard7, 26); put(.keyboard8, 28)
        put(.keyboard9, 25); put(.keyboard0, 29)

        // Punctuation and editing
        put(.keyboardReturnOrEnter, 36)
        put(.keyboardEscape, 53)
        put(.keyboardDeleteOrBackspace, 51)
        put(.keyboardTab, 48)
        put(.keyboardSpacebar, 49)
        put(.keyboardHyphen, 27)
        put(.keyboardEqualSign, 24)
        put(.keyboardOpenBracket, 33)
        put(.keyboardCloseBracket, 30)
        put(.keyboardBackslash, 42)
        put(.keyboardSemicolon, 41)
        put(.keyboardQuote, 39)
        put(.keyboardGraveAccentAndTilde, 50)
        put(.keyboardComma, 43)
        put(.keyboardPeriod, 47)
        put(.keyboardSlash, 44)
        put(.keyboardCapsLock, 57)

        // Navigation
        put(.keyboardRightArrow, 124)
        put(.keyboardLeftArrow, 123)
        put(.keyboardDownArrow, 125)
        put(.keyboardUpArrow, 126)
        put(.keyboardHome, 115)
        put(.keyboardEnd, 119)
        put(.keyboardPageUp, 116)
        put(.keyboardPageDown, 121)
        put(.keyboardDeleteForward, 117)

        // Function row
        put(.keyboardF1, 122); put(.keyboardF2, 120); put(.keyboardF3, 99);  put(.keyboardF4, 118)
        put(.keyboardF5, 96);  put(.keyboardF6, 97);  put(.keyboardF7, 98);  put(.keyboardF8, 100)
        put(.keyboardF9, 101); put(.keyboardF10, 109); put(.keyboardF11, 103); put(.keyboardF12, 111)

        // Keypad
        put(.keypadSlash, 75);    put(.keypadAsterisk, 67); put(.keypadHyphen, 78)
        put(.keypadPlus, 69);     put(.keypadEnter, 76);    put(.keypadEqualSign, 81)
        put(.keypadPeriod, 65)
        put(.keypad0, 82); put(.keypad1, 83); put(.keypad2, 84); put(.keypad3, 85); put(.keypad4, 86)
        put(.keypad5, 87); put(.keypad6, 88); put(.keypad7, 89); put(.keypad8, 91); put(.keypad9, 92)

        // Modifiers
        put(.keyboardLeftControl, 59)
        put(.keyboardLeftShift, 56)
        put(.keyboardLeftAlt, 58)
        put(.keyboardLeftGUI, 55)
        put(.keyboardRightControl, 62)
        put(.keyboardRightShift, 60)
        put(.keyboardRightAlt, 61)
        put(.keyboardRightGUI, 54)

        return map
    }()
}
