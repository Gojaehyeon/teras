import CoreGraphics
import Foundation

/// macOS virtual key codes → Android key codes (CONTROL.md §7).
///
/// The Carbon `kVK_*` constants are written out as raw integers so this file
/// does not need the Carbon framework, and so the table reads as data.
enum KeyMap {

    // MARK: - Android key codes worth naming

    enum Android {
        static let back: UInt32 = 4
        static let home: UInt32 = 3
        static let power: UInt32 = 26
        static let appSwitch: UInt32 = 187

        static let dpadUp: UInt32 = 19
        static let dpadDown: UInt32 = 20
        static let dpadLeft: UInt32 = 21
        static let dpadRight: UInt32 = 22

        static let enter: UInt32 = 66
        static let del: UInt32 = 67            // backspace
        static let forwardDel: UInt32 = 112
        static let tab: UInt32 = 61
        static let space: UInt32 = 62
        static let escape: UInt32 = 111
        static let insert: UInt32 = 124
        static let capsLock: UInt32 = 115

        static let moveHome: UInt32 = 122
        static let moveEnd: UInt32 = 123
        static let pageUp: UInt32 = 92
        static let pageDown: UInt32 = 93

        static let shiftLeft: UInt32 = 59
        static let shiftRight: UInt32 = 60
        static let altLeft: UInt32 = 57
        static let altRight: UInt32 = 58
        static let ctrlLeft: UInt32 = 113
        static let ctrlRight: UInt32 = 114
        static let metaLeft: UInt32 = 117
        static let metaRight: UInt32 = 118

        static let volumeUp: UInt32 = 24
        static let volumeDown: UInt32 = 25
        static let volumeMute: UInt32 = 164
    }

    /// `KeyEvent.META_*`. The generic bit and the matching LEFT bit are both
    /// set, because Android apps test either one.
    enum Meta {
        static let shiftOn: UInt32 = 0x0000_0001
        static let shiftLeftOn: UInt32 = 0x0000_0040
        static let altOn: UInt32 = 0x0000_0002
        static let altLeftOn: UInt32 = 0x0000_0010
        static let ctrlOn: UInt32 = 0x0000_1000
        static let ctrlLeftOn: UInt32 = 0x0000_2000
        static let metaOn: UInt32 = 0x0001_0000
        static let metaLeftOn: UInt32 = 0x0002_0000
        static let capsLockOn: UInt32 = 0x0010_0000
    }

    // MARK: - The table

    /// macOS virtual key code → Android key code.
    static let table: [Int: UInt32] = {
        var map: [Int: UInt32] = [:]

        // Letters. Android KEYCODE_A is 29 and the alphabet is contiguous.
        let letters: [(Int, Character)] = [
            (0x00, "a"), (0x0B, "b"), (0x08, "c"), (0x02, "d"), (0x0E, "e"), (0x03, "f"),
            (0x05, "g"), (0x04, "h"), (0x22, "i"), (0x26, "j"), (0x28, "k"), (0x25, "l"),
            (0x2E, "m"), (0x2D, "n"), (0x1F, "o"), (0x23, "p"), (0x0C, "q"), (0x0F, "r"),
            (0x01, "s"), (0x11, "t"), (0x20, "u"), (0x09, "v"), (0x0D, "w"), (0x07, "x"),
            (0x10, "y"), (0x06, "z"),
        ]
        for (code, letter) in letters {
            let offset = letter.asciiValue! - Character("a").asciiValue!
            map[code] = 29 + UInt32(offset)
        }

        // Digits along the top row. Android KEYCODE_0 is 7.
        let digits: [(Int, Int)] = [
            (0x1D, 0), (0x12, 1), (0x13, 2), (0x14, 3), (0x15, 4),
            (0x17, 5), (0x16, 6), (0x1A, 7), (0x1C, 8), (0x19, 9),
        ]
        for (code, digit) in digits { map[code] = 7 + UInt32(digit) }

        // Numeric keypad. Android KEYCODE_NUMPAD_0 is 144.
        let keypad: [(Int, Int)] = [
            (0x52, 0), (0x53, 1), (0x54, 2), (0x55, 3), (0x56, 4),
            (0x57, 5), (0x58, 6), (0x59, 7), (0x5B, 8), (0x5C, 9),
        ]
        for (code, digit) in keypad { map[code] = 144 + UInt32(digit) }
        map[0x4B] = 154   // NUMPAD_DIVIDE
        map[0x43] = 155   // NUMPAD_MULTIPLY
        map[0x4E] = 156   // NUMPAD_SUBTRACT
        map[0x45] = 157   // NUMPAD_ADD
        map[0x41] = 158   // NUMPAD_DOT
        map[0x4C] = 160   // NUMPAD_ENTER
        map[0x51] = 161   // NUMPAD_EQUALS

        // Function keys. Android KEYCODE_F1 is 131.
        let functionKeys: [(Int, Int)] = [
            (0x7A, 1), (0x78, 2), (0x63, 3), (0x76, 4), (0x60, 5), (0x61, 6),
            (0x62, 7), (0x64, 8), (0x65, 9), (0x6D, 10), (0x67, 11), (0x6F, 12),
        ]
        for (code, number) in functionKeys { map[code] = 131 + UInt32(number - 1) }

        // Editing and navigation.
        map[0x24] = Android.enter          // Return
        map[0x33] = Android.del            // Delete (backspace)
        map[0x75] = Android.forwardDel     // Forward delete
        map[0x30] = Android.tab
        map[0x31] = Android.space
        map[0x35] = Android.back           // Escape → BACK, per CONTROL.md §7
        map[0x73] = Android.moveHome       // Home
        map[0x77] = Android.moveEnd        // End
        map[0x74] = Android.pageUp
        map[0x79] = Android.pageDown
        map[0x72] = Android.insert         // Help sits where Insert does on a PC
        map[0x7B] = Android.dpadLeft
        map[0x7C] = Android.dpadRight
        map[0x7D] = Android.dpadDown
        map[0x7E] = Android.dpadUp

        // Punctuation.
        map[0x1B] = 69   // MINUS
        map[0x18] = 70   // EQUALS
        map[0x21] = 71   // LEFT_BRACKET
        map[0x1E] = 72   // RIGHT_BRACKET
        map[0x2A] = 73   // BACKSLASH
        map[0x29] = 74   // SEMICOLON
        map[0x27] = 75   // APOSTROPHE
        map[0x32] = 68   // GRAVE
        map[0x2B] = 55   // COMMA
        map[0x2F] = 56   // PERIOD
        map[0x2C] = 76   // SLASH

        // Modifiers and media, so a held modifier reaches the phone as a key.
        map[0x38] = Android.shiftLeft
        map[0x3C] = Android.shiftRight
        map[0x3A] = Android.altLeft
        map[0x3D] = Android.altRight
        map[0x3B] = Android.ctrlLeft
        map[0x3E] = Android.ctrlRight
        map[0x37] = Android.metaLeft
        map[0x36] = Android.metaRight
        map[0x39] = Android.capsLock
        map[0x48] = Android.volumeUp
        map[0x49] = Android.volumeDown
        map[0x4A] = Android.volumeMute

        return map
    }()

    /// The Android key code for a macOS virtual key code, if there is one.
    static func androidKeyCode(forMacKeyCode keyCode: Int) -> UInt32? {
        table[keyCode]
    }

    /// macOS virtual key codes that are modifiers, so the caller can track
    /// which ones are held and release them on capture exit.
    static let modifierKeyCodes: Set<Int> = [0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x37, 0x36, 0x39]

    static func isModifier(macKeyCode: Int) -> Bool { modifierKeyCodes.contains(macKeyCode) }

    // MARK: - Modifier flags

    /// `CGEventFlags` → Android `metaState`.
    static func metaState(from flags: CGEventFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.maskShift) { meta |= Meta.shiftOn | Meta.shiftLeftOn }
        if flags.contains(.maskAlternate) { meta |= Meta.altOn | Meta.altLeftOn }
        if flags.contains(.maskControl) { meta |= Meta.ctrlOn | Meta.ctrlLeftOn }
        if flags.contains(.maskCommand) { meta |= Meta.metaOn | Meta.metaLeftOn }
        if flags.contains(.maskAlphaShift) { meta |= Meta.capsLockOn }
        return meta
    }

    // MARK: - Text fallback

    /// Whether an unmapped key's characters should go out as TEXT.
    ///
    /// True for ordinary printable text — a Korean syllable, an accented
    /// letter, a symbol from a layout the table does not cover. False for the
    /// empty string and for control characters, which would otherwise arrive
    /// on the phone as stray glyphs.
    static func isPrintableFallback(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        for scalar in string.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                return false
            default:
                continue
            }
        }
        return true
    }

    /// The characters a key event would type, or nil if it types nothing.
    static func unicodeString(for event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
