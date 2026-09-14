package app.tandem.receiver.input

import android.view.KeyEvent as AndroidKeyEvent

/**
 * Android key codes to macOS virtual key codes (PROTOCOL.md §6.3).
 *
 * The host prefers a real virtual key code because it preserves shortcuts and
 * key repeat; where there is no equivalent the receiver sends `keyCode = 0` and
 * the host inserts [KeyEvent.text] as a Unicode key event instead.
 *
 * The table is the ANSI layout from Carbon's `Events.h` (`kVK_*`), which is what
 * `CGEventCreateKeyboardEvent` takes.
 */
object KeyMapper {
    const val NO_KEY_CODE = 0

    const val MOD_CMD = "cmd"
    const val MOD_SHIFT = "shift"
    const val MOD_ALT = "alt"
    const val MOD_CTRL = "ctrl"

    private val TABLE: Map<Int, Int> =
        mapOf(
            AndroidKeyEvent.KEYCODE_A to 0,
            AndroidKeyEvent.KEYCODE_S to 1,
            AndroidKeyEvent.KEYCODE_D to 2,
            AndroidKeyEvent.KEYCODE_F to 3,
            AndroidKeyEvent.KEYCODE_H to 4,
            AndroidKeyEvent.KEYCODE_G to 5,
            AndroidKeyEvent.KEYCODE_Z to 6,
            AndroidKeyEvent.KEYCODE_X to 7,
            AndroidKeyEvent.KEYCODE_C to 8,
            AndroidKeyEvent.KEYCODE_V to 9,
            AndroidKeyEvent.KEYCODE_B to 11,
            AndroidKeyEvent.KEYCODE_Q to 12,
            AndroidKeyEvent.KEYCODE_W to 13,
            AndroidKeyEvent.KEYCODE_E to 14,
            AndroidKeyEvent.KEYCODE_R to 15,
            AndroidKeyEvent.KEYCODE_Y to 16,
            AndroidKeyEvent.KEYCODE_T to 17,
            AndroidKeyEvent.KEYCODE_1 to 18,
            AndroidKeyEvent.KEYCODE_2 to 19,
            AndroidKeyEvent.KEYCODE_3 to 20,
            AndroidKeyEvent.KEYCODE_4 to 21,
            AndroidKeyEvent.KEYCODE_6 to 22,
            AndroidKeyEvent.KEYCODE_5 to 23,
            AndroidKeyEvent.KEYCODE_EQUALS to 24,
            AndroidKeyEvent.KEYCODE_9 to 25,
            AndroidKeyEvent.KEYCODE_7 to 26,
            AndroidKeyEvent.KEYCODE_MINUS to 27,
            AndroidKeyEvent.KEYCODE_8 to 28,
            AndroidKeyEvent.KEYCODE_0 to 29,
            AndroidKeyEvent.KEYCODE_RIGHT_BRACKET to 30,
            AndroidKeyEvent.KEYCODE_O to 31,
            AndroidKeyEvent.KEYCODE_U to 32,
            AndroidKeyEvent.KEYCODE_LEFT_BRACKET to 33,
            AndroidKeyEvent.KEYCODE_I to 34,
            AndroidKeyEvent.KEYCODE_P to 35,
            AndroidKeyEvent.KEYCODE_ENTER to 36,
            AndroidKeyEvent.KEYCODE_L to 37,
            AndroidKeyEvent.KEYCODE_J to 38,
            AndroidKeyEvent.KEYCODE_APOSTROPHE to 39,
            AndroidKeyEvent.KEYCODE_K to 40,
            AndroidKeyEvent.KEYCODE_SEMICOLON to 41,
            AndroidKeyEvent.KEYCODE_BACKSLASH to 42,
            AndroidKeyEvent.KEYCODE_COMMA to 43,
            AndroidKeyEvent.KEYCODE_SLASH to 44,
            AndroidKeyEvent.KEYCODE_N to 45,
            AndroidKeyEvent.KEYCODE_M to 46,
            AndroidKeyEvent.KEYCODE_PERIOD to 47,
            AndroidKeyEvent.KEYCODE_TAB to 48,
            AndroidKeyEvent.KEYCODE_SPACE to 49,
            AndroidKeyEvent.KEYCODE_GRAVE to 50,
            AndroidKeyEvent.KEYCODE_DEL to 51,
            AndroidKeyEvent.KEYCODE_ESCAPE to 53,
            AndroidKeyEvent.KEYCODE_META_LEFT to 55,
            AndroidKeyEvent.KEYCODE_SHIFT_LEFT to 56,
            AndroidKeyEvent.KEYCODE_CAPS_LOCK to 57,
            AndroidKeyEvent.KEYCODE_ALT_LEFT to 58,
            AndroidKeyEvent.KEYCODE_CTRL_LEFT to 59,
            AndroidKeyEvent.KEYCODE_SHIFT_RIGHT to 60,
            AndroidKeyEvent.KEYCODE_ALT_RIGHT to 61,
            AndroidKeyEvent.KEYCODE_CTRL_RIGHT to 62,
            AndroidKeyEvent.KEYCODE_META_RIGHT to 55,
            AndroidKeyEvent.KEYCODE_NUMPAD_DOT to 65,
            AndroidKeyEvent.KEYCODE_NUMPAD_MULTIPLY to 67,
            AndroidKeyEvent.KEYCODE_NUMPAD_ADD to 69,
            AndroidKeyEvent.KEYCODE_NUM_LOCK to 71,
            AndroidKeyEvent.KEYCODE_VOLUME_UP to 72,
            AndroidKeyEvent.KEYCODE_VOLUME_DOWN to 73,
            AndroidKeyEvent.KEYCODE_VOLUME_MUTE to 74,
            AndroidKeyEvent.KEYCODE_NUMPAD_DIVIDE to 75,
            AndroidKeyEvent.KEYCODE_NUMPAD_ENTER to 76,
            AndroidKeyEvent.KEYCODE_NUMPAD_SUBTRACT to 78,
            AndroidKeyEvent.KEYCODE_NUMPAD_EQUALS to 81,
            AndroidKeyEvent.KEYCODE_NUMPAD_0 to 82,
            AndroidKeyEvent.KEYCODE_NUMPAD_1 to 83,
            AndroidKeyEvent.KEYCODE_NUMPAD_2 to 84,
            AndroidKeyEvent.KEYCODE_NUMPAD_3 to 85,
            AndroidKeyEvent.KEYCODE_NUMPAD_4 to 86,
            AndroidKeyEvent.KEYCODE_NUMPAD_5 to 87,
            AndroidKeyEvent.KEYCODE_NUMPAD_6 to 88,
            AndroidKeyEvent.KEYCODE_NUMPAD_7 to 89,
            AndroidKeyEvent.KEYCODE_NUMPAD_8 to 91,
            AndroidKeyEvent.KEYCODE_NUMPAD_9 to 92,
            AndroidKeyEvent.KEYCODE_F5 to 96,
            AndroidKeyEvent.KEYCODE_F6 to 97,
            AndroidKeyEvent.KEYCODE_F7 to 98,
            AndroidKeyEvent.KEYCODE_F3 to 99,
            AndroidKeyEvent.KEYCODE_F8 to 100,
            AndroidKeyEvent.KEYCODE_F9 to 101,
            AndroidKeyEvent.KEYCODE_F11 to 103,
            AndroidKeyEvent.KEYCODE_F10 to 109,
            AndroidKeyEvent.KEYCODE_F12 to 111,
            AndroidKeyEvent.KEYCODE_MOVE_HOME to 115,
            AndroidKeyEvent.KEYCODE_PAGE_UP to 116,
            AndroidKeyEvent.KEYCODE_FORWARD_DEL to 117,
            AndroidKeyEvent.KEYCODE_F4 to 118,
            AndroidKeyEvent.KEYCODE_MOVE_END to 119,
            AndroidKeyEvent.KEYCODE_F2 to 120,
            AndroidKeyEvent.KEYCODE_PAGE_DOWN to 121,
            AndroidKeyEvent.KEYCODE_F1 to 122,
            AndroidKeyEvent.KEYCODE_DPAD_LEFT to 123,
            AndroidKeyEvent.KEYCODE_DPAD_RIGHT to 124,
            AndroidKeyEvent.KEYCODE_DPAD_DOWN to 125,
            AndroidKeyEvent.KEYCODE_DPAD_UP to 126,
        )

    /** The macOS virtual key code, or [NO_KEY_CODE] when the host should use text. */
    fun virtualKeyCode(androidKeyCode: Int): Int = TABLE[androidKeyCode] ?: NO_KEY_CODE

    /** Keys the receiver keeps for itself rather than forwarding to the host. */
    fun isLocalKey(androidKeyCode: Int): Boolean =
        androidKeyCode == AndroidKeyEvent.KEYCODE_BACK ||
            androidKeyCode == AndroidKeyEvent.KEYCODE_HOME ||
            androidKeyCode == AndroidKeyEvent.KEYCODE_APP_SWITCH ||
            androidKeyCode == AndroidKeyEvent.KEYCODE_POWER

    fun modifiers(metaState: Int): List<String> =
        buildList {
            if (metaState and AndroidKeyEvent.META_META_ON != 0) add(MOD_CMD)
            if (metaState and AndroidKeyEvent.META_SHIFT_ON != 0) add(MOD_SHIFT)
            if (metaState and AndroidKeyEvent.META_ALT_ON != 0) add(MOD_ALT)
            if (metaState and AndroidKeyEvent.META_CTRL_ON != 0) add(MOD_CTRL)
        }
}
