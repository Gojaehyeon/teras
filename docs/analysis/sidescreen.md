# SideScreen architecture report

Source: `/Users/go/lab/ref/SideScreen` @ `fcddb9e` (v0.11.3), MIT licensed.
Mac host in Swift under `MacHost/`, Android client in Kotlin under `AndroidClient/`.
No files in that repository were modified during this analysis.

## 1. Virtual display

Private CoreGraphics API, hand-declared in `MacHost/Sources/CGVirtualDisplayBridge.h:16-63`
(`CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings`,
`CGVirtualDisplay`) and bridged via `MacHost/Sources/module.modulemap`. No dlopen, no
`-F /System/Library/PrivateFrameworks`: the classes live in already-linked CoreGraphics,
so the Objective-C runtime resolves them. SwiftPM passes
`-Xcc -fmodule-map-file=Sources/module.modulemap` (`MacHost/Package.swift:26`).

Creation: `MacHost/Sources/VirtualDisplayManager.swift:28-106`. HiDPI is faked by doubling
pixels and lying about physical size, 220 PPI versus 110 (`:50-54`), plus a two-entry mode
list where the physical mode is an "anchor" that unlocks Retina for the logical mode
(`:71-84`). `productID = physW*10000 + physH` avoids portrait/landscape collision (`:58`);
`vendorID = 0xEEEE` later distinguishes its own displays from real ones (`:314`).

Rotation never touches the display. It is a width/height swap in settings
(`MacHost/Sources/SettingsWindow.swift:1396-1399`) plus a transform integer sent to the client.

Teardown is `virtualDisplay = nil` (`:372-380`). Position is persisted to `UserDefaults` but
applied `.forSession` so WindowServer never bakes the virtual display into permanent prefs
(`:251-254`). Substantial code exists solely to stop it becoming the main display and
stranding the menu bar on an invisible screen (`:318-347`, issue #39).

## 2. Capture

ScreenCaptureKit primary, CGDisplayStream fallback. `SCContentFilter` on the matching
`displayID`, retried five times because the display takes time to appear
(`MacHost/Sources/ScreenCapture.swift:285-313`).

Config at `:347-363`: `minimumFrameInterval` 1/fps, `queueDepth = 4`, cursor on,
`scalesToFit = false`, pixel format `420YpCbCr8BiPlanarVideoRange`. Video range beats full
range because some Android vendor paths apply a limited-range matrix regardless of the VUI
flag (`:351-357`).

SCStream downscales to encode size, so HiDPI is a 2x render downsampled to what the client
can decode (`:144-164`). The fallback mirrors this via `outputWidth/Height` (`:690-696`) and
must set `showCursor` explicitly, which defaults to false (`:684-688`).

Two watchdogs: a 3 s timer declaring a stall after 5 s, replaying the last frame or
restarting (`:480-536`); and wake observers rebuilding 2 s after screen wake, since display
sleep kills SCStream with -3815 (`:196-256`). An `IOPMAssertion` prevents idle display sleep
for the session (`:619-630`).

## 3. Encoding

VideoToolbox, HEVC default, H.264 only on client request
(`MacHost/Sources/VideoEncoder.swift:45-136`).

| Property | Value |
|---|---|
| Profile | `HEVC_Main_AutoLevel` / `H264_Main_AutoLevel` (`:74-76`) |
| Bitrate | `max(bitrateMbps, 60)` Mbps; 50 in gaming boost (`:82-84`) |
| GOP | `MaxKeyFrameInterval = fps`, duration 1.0 s (`:96-97`) |
| Realtime | `RealTime`, `AllowFrameReordering = false`, `MaxFrameDelayCount = 0` (`:69, :100, :103`) |
| Quality | 0.3 to 0.9 by preset (`:106-118`) |
| Color | BT.709 primaries, transfer, matrix pinned (`:128-130`) |

VBR; `DataRateLimits` and `ConstantBitRate` both removed deliberately. Output converts
length-prefixed NAL units to Annex-B with VPS/SPS/PPS prepended on every keyframe
(`:232-278`). Default bitrate setting is 1000 Mbps (`SettingsWindow.swift:1286`), unclamped.

## 4. Transport

TCP over `Network.framework`, `noDelay`, default port 54321
(`MacHost/Sources/StreamingServer.swift:250-258`; `SettingsWindow.swift:1291`, moved off 8888
for collisions with Jupyter, Splunk and HP printers). Type tags at `StreamingServer.swift:5-32`.

Server to client, **big-endian**:

- `1` displayConfig `[w:i32][h:i32][transform:i32]`, transform = rotation + 1000*flipH + 2000*flipV (`:592-603`)
- `6` frame `[size:i32][keyframe:u8][captureTs:u64]` (`:841-860`)
- `0` legacy frame, `5` pong, `10` codecSelected, `13` desktopGeometry

Client to server, **little-endian** (`AndroidClient/.../StreamClient.kt:519, 589`):

- `2` touch, `4` ping, `7` keyframeRequest
- payload-free opt-ins `8` frame-metadata, `9` AVC-only, `12` desktop-geometry
- `11` decoder limits

The two directions use opposite byte orders and happen to agree, because Java's
`DataInputStream` is big-endian while the Mac reads touch floats with native-endian
`loadUnaligned` (`StreamingServer.swift:781-792`). Correct today, undocumented, and one
refactor from silent breakage.

Type `11` encodes the decoder ceiling in four bytes with the high bit forced, so old hosts
skipping unknown types byte-by-byte never mistake payload for a tag (`:728-741`,
`StreamClient.kt:420-431`). Ordering is load-bearing: 9, 11, 12 must precede 8
(`StreamClient.kt:132-135`). Negotiation runs inside a 100 ms grace window before the first
frame (`StreamingServer.swift:383-386`), the protocol's weakest joint.

**USB has no handshake**: loopback skips auth entirely (`:363-366`). Transport is
`adb reverse tcp:P tcp:P`, run by the app itself. adb is found by probing four hardcoded
paths then `which`, cached 5 s (`AppDelegate.swift:443-448`, `StatusDetector.swift:68-72`).
Attach is polled by parsing `adb devices` and `adb reverse --list` as strings
(`StatusDetector.swift:17-57`).

**Wireless** uses a QR carrying `sidescreen://host:port?t=<b64url>&name=`
(`PairingURL.swift:9`) or an 8-digit typed code for camera-less tablets. Token is 32 bytes
from `SecRandomCopyBytes`, held in `UserDefaults`, compared in constant time
(`WirelessAuth.swift:7-43`). Handshake is `"SSWA"` + token + name, reply `"SSWR"` + status
(`HandshakeCodec.swift:33-71`); the code path uses `"SSPC"`/`"SSPR"`, padded to the same
37-byte prefix so old hosts fail cleanly rather than stall (`:37-45`). Five attempts, then
the code is burned (`StreamingServer.swift:187`).

## 5. Input

Touch only, two pointers maximum. Payload `[type][count][x:f32][y:f32](xN)[action:i32]`,
normalized 0..1 against the view (`StreamingServer.swift:663-679`; `MainActivity.kt:1510-1564`).

No keyboard, pen, mouse button, or scroll message exists in either codebase. The Mac
synthesizes all of it with `CGEvent` on a `.hidSystemState` source (`AppDelegate.swift:805`),
mapping to `CGDisplayBounds` of the virtual display (`:851-861`). A gesture state machine
produces click, double click, right click via long press, drag, momentum scroll, and
Cmd-scroll zoom (`:872-1067`). `AXIsProcessTrusted()` gates every event (`:840`).

`InputPredictor.kt:43-74` extrapolates two samples on a hardcoded 12 ms horizon
(`MainActivity.kt:1543`); the measured ping round-trip time is never fed into it.

## 6. Android client

`MediaCodec` to a Surface, async callbacks on a `THREAD_PRIORITY_DISPLAY` thread
(`VideoDecoder.kt:91-139`). Three-tier configure ladder: `KEY_LOW_LATENCY` + `KEY_PRIORITY`
+ `KEY_OPERATING_RATE`, then without low latency, then bare resolution (`:148-206`). No
vendor low-latency keys. Codec choice excludes software decoders and blacklisted Spreadtrum
parts that configure and start but never render to a Surface
(`CodecCapabilities.kt:29, 53-65`).

`csd-0` is never set; parameter sets arrive inline in the byte stream and the decoder drops
frames until the first sync frame (`VideoDecoder.kt:333-341`). Output uses
`releaseOutputBuffer(index, true)`, never the timestamped form, and drops frames whose
computed latency exceeds 100 ms (`:470-489`). **No Choreographer or vsync pacing anywhere.**
Presentation timestamps double as a wall clock (`:379, :448`), so any decoder that rewrites
or reorders them silently disables stale-frame dropping.

Connects to `127.0.0.1:54321` over adb reverse, or a WiFi-bound socket on LAN with a 5 s
timeout (`StreamClient.kt:121-128, 183-209`). No automatic reconnect
(`WirelessTabController.kt:122-124`). The client distinguishes the adb daemon from the real
host by connecting and waiting 200 ms for bytes (`MainActivity.kt:1746-1774`).

**No foreground service exists**: no `<service>` element, no `FOREGROUND_SERVICE` permission.
Streaming lives entirely in the Activity, which does not override `onPause` or `onStop`
(`MainActivity.kt:1623-1627`). A `PARTIAL_WAKE_LOCK` expires after 30 minutes and is never
renewed (`:243-249`). Orientation is locked from the host's reported rotation while
streaming (`:1566-1577`), with cutout and immersive handling at `:102-105, 264-285`.

## 7. Permissions, signing, packaging

Screen Recording and Accessibility, both runtime-prompted. Local Network plus a
`_sidescreen._tcp` Bonjour entry (`scripts/build_mac.sh:87-94`).

Pure SwiftPM, no Xcode project. Two `swift build -c release` runs, `lipo` into a universal
binary, a hand-assembled `.app` with a heredoc Info.plist (`:25-97`), **ad-hoc signed** with
`codesign --sign -` (`:101`), then `hdiutil` into a DMG. Sandbox off, library validation
disabled, unsigned executable memory allowed (`MacHost/SideScreen.entitlements`). Not
Developer ID signed, not notarized, not stapled; users are told to run `sudo xattr -cr`
(`README.md:208-210`). CI on `macos-14` builds and lints only
(`.github/workflows/build-mac.yml`); the release workflow also ad-hoc signs
(`.github/workflows/release.yml:87`). Android release builds use the **debug signing config**
with minification off (`AndroidClient/app/build.gradle.kts:22-27`).

## 8. Weaknesses

- **100 ms capability window** (`StreamingServer.swift:383`) races slow devices; a late
  decoder limit forces a mid-session encoder rebuild (`:746-758`).
- **`lastPixelBuffer` is unsynchronized** across the capture callback and main thread
  (`ScreenCapture.swift:407, 510`), unlike every other shared field there. Stats counters
  likewise.
- **`stop()` calls `frameQueue.sync {}`** from an arbitrary thread (`:907-908`), a deadlock
  shape.
- **No send backpressure.** Frame-age dropping is explicitly disabled (`:822`); flow control
  is only the two-deep encode queue.
- **USB trusts loopback unconditionally**, so any local process can inject synthetic input.
- **Cleartext token on LAN.** `usesCleartextTraffic="true"`, no TLS, no nonce, no replay
  protection, stored as unencrypted Base64 (`PairedHostStorage.kt:26`).
- **No read timeout** on the streaming socket; pings go out every second but a missing pong
  is never acted on.
- **Unknown message type is fatal client-side** (`StreamClient.kt:486-492`), so any new
  server-to-client message breaks older clients, despite the careful high-bit escaping used
  in the opposite direction.
- **Use-after-release window**: `release()` nulls the decoder without joining the callback
  thread (`VideoDecoder.kt:529-541`).
- **Duplicate callback wiring**: `connect()` re-implements `setupStreamClientCallbacks()` but
  omits `onDecoderStalled` and the wireless branches (`MainActivity.kt:1301-1425` versus
  `:1050-1157`), with a buffer-pool leak on one null-decoder path (`:1055-1057`).
- **Hardcoded values**: adb paths, `0xEEEE`, 500 ms keyframe throttle, 2 s wake delay, 5 s
  stall timeout, 60 Mbps bitrate floor, 1000 Mbps default, 100 ms stale threshold, 12 ms
  prediction horizon, 32 MB frame cap, 30 min wakelock. `scripts/setup-usb.sh` and
  `scripts/run.sh` still use port 8888 while the app defaults to 54321.
- **Private API risk**: `CGVirtualDisplay` can change shape in any macOS release, and there
  is no fallback when `initWithDescriptor:` returns nil.

## 9. Reuse versus rewrite

**Take nearly verbatim under MIT**: `CGVirtualDisplayBridge.h` and the modulemap wiring; the
HiDPI anchor-mode trick (`VirtualDisplayManager.swift:38-84`); the main-display safety net
(`:318-347`); the VideoToolbox property set including the BT.709 and video-range pairing
(`VideoEncoder.swift:69-130`); the Annex-B conversion; `CodecLimits.swift` whole; the
hardware-decoder blacklist (`CodecCapabilities.kt:29`); the adb-daemon-versus-real-host probe
(`MainActivity.kt:1746-1774`).

**Rewrite for a commercial product**: the wire protocol (no envelope, no version field, mixed
endianness, capability negotiation on a timer, load-bearing message ordering, fatal unknown
types); the input layer (touch-only, gestures synthesized host-side, no keyboard or pen); the
Android session model, which needs a real foreground service; connection lifecycle and
reconnection; signing and notarization end to end; and `AppDelegate.swift` plus
`SettingsWindow.swift`, 2,945 lines mixing UI, orchestration, adb shelling, and CGEvent
synthesis with no seam between them.
