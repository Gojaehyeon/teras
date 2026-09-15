# Teras control server

The Android half of Teras Control (`docs/CONTROL.md`, protocol v1): a plain
Java program — **not an Android app** — dexed into a single jar and run on the
phone as the `shell` UID. It listens on an abstract local socket, and injects
mouse and keyboard events into whatever is on screen through the framework's
hidden input APIs. No root, no installed app, no runtime permission.

```
Mac  ──adb forward tcp:N localabstract:teras_control_<token>──▶  Server
                                                                  │
                                    InputManagerGlobal#injectInputEvent
                                                                  ▼
                                                        the phone's own UI
```

## Layout

| path | what |
|------|------|
| `src/app/teras/control/Server.java` | main, socket, message dispatch, display poller, lifetime |
| `src/app/teras/control/Framing.java` | wire format; **no Android imports**, so it unit-tests on a desktop JVM |
| `src/app/teras/control/Injector.java` | MotionEvent/KeyEvent construction and injection by reflection |
| `src/app/teras/control/DisplayInfoReader.java` | `DisplayManagerGlobal#getDisplayInfo(0)`, with a `wm`/`dumpsys` fallback |
| `src/app/teras/control/Log.java` | stderr logging with the `[teras-control]` prefix the Mac greps for |
| `test/app/teras/control/FramingTest.java` | desktop JVM test, run by `build.sh` |
| `test_client.py` | end-to-end device test against a forwarded port |

## Build

```sh
./build.sh
```

Compiles with `javac --release 17` against `android.jar`, runs the framing unit
test on the desktop JVM, dexes with `d8 --min-api 26`, packages
`build/teras-control.jar` (a zip holding `classes.dex` at the root) and copies
it to `MacHost/Resources/teras-control.jar`.

Overridable environment: `ANDROID_HOME` (default `~/Library/Android/sdk`),
`COMPILE_SDK` (35), `BUILD_TOOLS` (35.0.0), `MIN_API` (26), `JAVA_HOME`
(default the JBR inside Android Studio).

## Run

```sh
adb push build/teras-control.jar /data/local/tmp/teras-control.jar
adb shell CLASSPATH=/data/local/tmp/teras-control.jar \
    app_process / app.teras.control.Server <token> [--verbose] [--device-id N]
adb forward tcp:0 localabstract:teras_control_<token>
```

`<token>` is the 16 hex chars from `docs/CONTROL.md` section 2; it only has to
match what the Mac forwards to. The server exits 5 s after its client
disconnects and on `SIGTERM`, so a stale instance never outlives a session.

`--self-test` runs the framing round-trip on the device and exits, which is a
quick way to prove the dex loads under `app_process`.

## Test

```sh
./build.sh                                  # includes the desktop unit test
adb forward tcp:0 localabstract:teras_control_<token>
python3 test_client.py <forwarded-port>     # add --no-click to hover only
```

`test_client.py` sends HELLO, prints DISPLAY_INFO and READY, circles the
pointer for two seconds, right-clicks the centre, scrolls, presses
`KEYCODE_BACK`, types `teras`, toggles pointer visibility and says BYE. It
exits non-zero if any ERROR frame arrives or READY reports that injection does
not work.

## Notes and limitations

* **No visible mouse cursor.** Android draws the system pointer from
  `InputReader`'s pointer controller, which only exists for a physically
  present mouse. Events delivered through `injectInputEvent` enter at the
  dispatcher, below that layer, so `dumpsys input` keeps
  `MousePointerControllers:` empty and nothing is drawn. Verified on Android 17
  with the default device id and with the id of a `SOURCE_MOUSE`-capable
  device (`--device-id`, which exists for exactly this experiment). Clicks,
  drags, hovers and scrolls all land correctly; they are simply invisible. A
  visible pointer needs either a Mac-side overlay or a `/dev/uhid` virtual
  mouse, neither of which is part of protocol v1.
* **`density` is the dp scale factor**, `logicalDensityDpi / 160`. CONTROL.md
  names the field but not its unit; 2.25 on a 360 dpi panel.
* `MotionEvent#setActionButton` is hidden and reflected. If a ROM hides it
  harder, `ACTION_BUTTON_PRESS` / `ACTION_BUTTON_RELEASE` are skipped and
  `ACTION_DOWN` / `ACTION_UP` alone still click.
* Characters with no `KeyCharacterMap.VIRTUAL_KEYBOARD` mapping are skipped and
  counted; the server answers one ERROR frame naming the count, and keeps
  running.
* API 34 moved the injection singleton from `InputManager.getInstance()` to
  `InputManagerGlobal.getInstance()`. Both are probed, newest first.
