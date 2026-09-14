# Teras Control — protocol v1

Universal‑Control‑style input from the Mac to an Android device: move the
Mac cursor past a screen edge and the mouse, keyboard and scroll wheel drive
the phone's *own* screen. Independent of the display session (PROTOCOL.md);
both can run at once. Android only.

## 1. Components

* **Control server** (`Receivers/Android/control-server`, Java) — a dex jar
  pushed to `/data/local/tmp/teras-control.jar` and started by the Mac with
  `adb shell CLASSPATH=/data/local/tmp/teras-control.jar app_process / app.teras.control.Server <token>`.
  Runs as the `shell` UID, injects events through
  `android.hardware.input.InputManager#injectInputEvent` (reflection) and reads
  display geometry from `DisplayManagerGlobal#getDisplayInfo(0)`
  (reflection). No root, no app permission.
* **Mac host** — `Control/` module: starts the server, forwards the socket,
  runs a CGEvent tap, owns the edge/capture state machine.

## 2. Transport

* Server listens on **`localabstract:teras_control_<token>`** (LocalServerSocket).
  `<token>` is 16 random hex chars the Mac passes on the command line, so a
  stale server from a previous launch is never confused with the new one.
* Mac runs `adb forward tcp:0 localabstract:teras_control_<token>` and dials
  `127.0.0.1:<port>`.
* Server accepts one client; a second connection replaces the first.
* Server exits when its client disconnects for more than 5 s, or on SIGTERM.

## 3. Framing

`[u16 length][u8 type][payload]`, big‑endian; `length` = 1 + payload bytes.
Max length 65535. Both directions.

## 4. Messages Mac → server

| type | name | payload |
|------|------|---------|
| 0x01 | HELLO | `[u8 version=1]` — server answers DISPLAY_INFO |
| 0x10 | POINTER_MOVE | `[f32 x][f32 y]` absolute, in the phone's current logical px |
| 0x11 | BUTTON | `[u8 button 0 left 1 right 2 middle][u8 down 0/1][f32 x][f32 y]` |
| 0x12 | SCROLL | `[f32 x][f32 y][f32 hDelta][f32 vDelta]` deltas in "wheel steps" (1.0 = one notch; positive v = content moves up, i.e. Android convention) |
| 0x20 | KEY | `[u8 down 0/1][u32 androidKeyCode][u32 metaState][u32 repeat]` |
| 0x21 | TEXT | UTF‑8 string (typed via `KeyCharacterMap.VIRTUAL_KEYBOARD`) |
| 0x30 | GET_DISPLAY | empty — server answers DISPLAY_INFO |
| 0x31 | SET_POINTER_VISIBLE | `[u8 0/1]` (server sends an off‑screen hover to hide when 0) |
| 0x40 | BYE | empty |

## 5. Messages server → Mac

| type | name | payload |
|------|------|---------|
| 0x80 | DISPLAY_INFO | `[u32 widthPx][u32 heightPx][u8 rotation 0‑3][f32 density]` logical size in the current rotation; re‑sent unsolicited whenever it changes (server polls every 500 ms) |
| 0x81 | ERROR | UTF‑8 message; server keeps running |
| 0x82 | PONG | `[u64 echo]` answer to PING |
| 0x8F | READY | `[u8 apiLevel][u8 flags bit0 = injection works]` sent once after HELLO, after a probe injection succeeded |

Mac → server PING is `0x32 [u64 t]`; the Mac sends one every 2 s and drops the
connection after 6 s of silence.

## 6. Injection semantics (server)

* Pointer events use `InputDevice.SOURCE_MOUSE`, one pointer, `TOOL_TYPE_MOUSE`.
  Move without buttons → `ACTION_HOVER_MOVE` (Android draws the system mouse
  pointer). Button down → `ACTION_DOWN` + `ACTION_BUTTON_PRESS`; drag →
  `ACTION_MOVE`; up → `ACTION_BUTTON_RELEASE` + `ACTION_UP`. `buttonState`
  and `actionButton` are set. Right button maps to `BUTTON_SECONDARY`.
* Scroll → `ACTION_SCROLL` with `AXIS_VSCROLL` / `AXIS_HSCROLL`.
* Keys → `KeyEvent(downTime, eventTime, action, keyCode, repeat, metaState,
  KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD)`.
* Injection mode `INJECT_INPUT_EVENT_MODE_ASYNC` (0).
* Coordinates are clamped to the display bounds.

## 7. Mac behaviour

* Prerequisite: Accessibility permission (event tap). Control is per Android
  device and off by default; the user turns it on in the menu.
* **Edge**: the phone is logically placed at the *right* edge of the
  right‑most Mac display by default (configurable: left/right). When the real
  cursor crosses that edge by ≥ 1 px, the host enters **captured** mode:
  * the event tap becomes active (events are swallowed),
  * the Mac cursor is pinned at the edge (`CGWarpMouseCursorPosition` each
    event) and hidden,
  * mouse deltas (`kCGMouseEventDeltaX/Y`, scaled by a user speed factor,
    default 1.5 phone px per Mac point) move a virtual pointer that starts at
    the phone's matching edge at the proportional y,
  * keyboard, scroll and buttons are forwarded.
* **Release**: the virtual pointer moves past the phone's edge that faces the
  Mac, or the user presses the escape chord **⌃⌥⌘ Esc**, or the device
  disconnects. On release the Mac cursor is unhidden and placed 8 px inside
  the edge.
* macOS key codes are mapped to Android key codes (letters, digits, F‑keys,
  arrows, return, tab, space, escape → BACK, delete → DEL, forward delete,
  home/end/page, punctuation); ⌘ → META_META, ⌥ → META_ALT, ⌃ → META_CTRL,
  ⇧ → META_SHIFT. Unmapped printable characters are sent as TEXT.
* Convenience chords while captured: ⌘H → HOME, ⌘⇧H → APP_SWITCH (recents),
  ⌘L → POWER (lock), ⌘V pastes the Mac clipboard as TEXT (server has no
  clipboard access at v1).
