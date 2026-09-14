# OpenDisplay Architecture Analysis

Source: `/Users/go/lab/ref/opendisplay` (GPLv3). Read-only analysis; no files in that
repo were modified. Releases up to v0.4.x were MIT-licensed and remain available under
those terms.

Layout: Mac sender in `Mac/`, iOS receiver in `iOS/`, shared code in `Shared/`,
standalone Mac receiver in `MacReceiver/`, spec in `PROTOCOL.md`, xcodegen config in
`project.yml`.

---

## 1. USB transport over usbmuxd

Hand-written, no third-party libraries, no `iproxy`, no libimobiledevice.

- Socket `/var/run/usbmuxd` (`Mac/Usbmux.swift:28`), opened as
  `NWConnection(to: .unix(path:))` (`Usbmux.swift:139`).
- Header is four little-endian `UInt32`s: total length, version=1, type=8 (plist),
  tag, followed by an XML plist body (`Usbmux.swift:170-175`).
- Requests used: `ListDevices`, `Listen`, `Connect`.
- Device identity from `ListDevices`, filtered to `ConnectionType == "USB"`, keyed on
  `DeviceID` (unstable, changes per replug) and `SerialNumber` (the stable UDID)
  (`Usbmux.swift:127-134`).
- Friendly name is a second dial to lockdownd on port 62078, whose framing differs:
  big-endian 4-byte length plus plist, no usbmux header (`Usbmux.swift:104-125`).

**Byte-order trap.** `Connect` wants the port in network byte order inside an otherwise
little-endian plist integer, so the code swaps by hand with `(port << 8) | (port >> 8)`
(`Usbmux.swift:71`). Result codes: 0 OK, 2 BadDevice, 3 refused (`Usbmux.swift:77-82`).
After OK the same socket becomes a transparent byte pipe to TCP 9000 on the device;
nothing usbmux-specific happens afterwards.

**Reconnection.** `UsbmuxDeviceWatcher` (`Usbmux.swift:218`) holds a long-lived `Listen`
subscription, seeds from `ListDevices` first because `Listen` only reports changes after
subscription begins (`Usbmux.swift:235`), handles `Attached`/`Detached`
(`Usbmux.swift:274-292`), and resubscribes after 3s on daemon error. Session-level
reconnect redials from scratch so a replugged device with a new `DeviceID` is found
again (`MacSender.swift:1310`, `MacSender.swift:1363`). Generation counters prevent a
stale in-flight async dial from adopting the connection.

## 2. iOS side

`NWListener` on TCP 9000, not BSD sockets (`Shared/StreamReceiver.swift:542`), with
`noDelay = true`, `allowLocalEndpointReuse = true`, `serviceClass = .interactiveVideo`
(`StreamReceiver.swift:536-541`). The same listener serves WiFi by attaching a Bonjour
service `_opensidecar._tcp` with TXT keys `id` and `pv` (`StreamReceiver.swift:245-250`).
usbmux-forwarded connections arrive from loopback, which is how the receiver labels
transport "USB" (`StreamReceiver.swift:554-557`). A newcomer connection must prove itself
by sending bytes before it evicts a live session (`StreamReceiver.swift:568-596`).

**Entitlements and background modes.** All three entitlements files are empty
dictionaries, and `project.yml` declares no `UIBackgroundModes` anywhere. There is no
background mode and no special entitlement. The app stays alive via
`isIdleTimerDisabled = true` (`iOS/OpenSidecarPhoneApp.swift:167`) plus a
`UIBackgroundTaskIdentifier` assertion worth roughly 30s; after iOS suspends the app the
kernel still accepts the Mac's redials, so the session survives an app switch
indefinitely (`OpenSidecarPhoneApp.swift:465-478`). Only a device lock or app quit ends
it, announced via `sleeping`/`closing`. WiFi mode needs Local Network permission; USB
does not.

**Decode.** Two paths. Default is `AVSampleBufferDisplayLayer.enqueue` with implicit
decode (`StreamReceiver.swift:1169`). An opt-in experimental path decodes explicitly with
`VTDecompressionSession` into NV12 with `kCVPixelBufferMetalCompatibilityKey`, then
converts YUV to RGB in a Metal fragment shader (`StreamReceiver.swift:1290`,
`iOS/MetalVideoRenderer.swift:1-13`). Their own measurements favour the system layer; the
Metal path mainly exists to obtain a true capture-to-photon number from the drawable's
presented handler.

## 3. Virtual display

`Mac/CGVirtualDisplayPrivate.h` is the reverse-engineered private CoreGraphics header,
credited to Khaos Tian's VirtualDisplayExp and shared with DeskPad and BetterDisplay.
`VirtualDisplay.swift:43-68` builds the descriptor (name, `maxPixelsWide/High`,
`sizeInMillimeters`, vendorID `0x5043`, productID `0x4F53`, serial), then applies
settings with `hiDPI = 1` and a single 60Hz mode. Points equal device pixels halved,
rounded down to even (`MacSender.swift:433-435`).

Three departures from a naive implementation, and this is where the real effort sits:

1. The descriptor reserves `max(w,h)` on **both** axes so rotation becomes a mode change
   on the same display rather than a destroy-and-recreate, which would scatter the user's
   windows (`VirtualDisplay.swift:36-38`, `:102`).
2. Mode selection is continuous enforcement, not one-shot: a 200ms-then-2s loop
   re-asserts the HiDPI mode, because macOS asynchronously restores stale saved state for
   that vendor/product/serial seconds later (`VirtualDisplay.swift:78-91`, `:152`).
3. The same loop breaks mirror sets macOS forms on its own, and must use `.forSession`
   scope because `.permanently` is rejected with `kCGErrorIllegalArgument` while still
   reporting success (`VirtualDisplay.swift:225-253`).

Separately, saved system state can "poison" an identity so the display is created but
never appears in `SCShareableContent`; the sender probes up to three serial/productID
offsets and persists the working one (`MacSender.swift:479-530`).

## 4. Capture and encode

`SCContentFilter(display:excludingWindows:[])`, `minimumFrameInterval` of 1/120
deliberately (asking 1/60 beats against the 60Hz display and measures ~51fps), pixel
format `420YpCbCr8BiPlanarVideoRange` to skip a BGRA-to-YUV conversion inside
VideoToolbox, `queueDepth = 8` (`MacSender.swift:677-702`).

Encoder settings (`MacSender.swift:1870-1917`):
`kVTVideoEncoderSpecification_EnableLowLatencyRateControl` with a fallback to no
specification, because AMD-only Macs have no encoder offering that mode; RealTime true,
`AllowFrameReordering` false, H.264 High AutoLevel, `MaxFrameDelayCount` 0,
`PrioritizeEncodingSpeedOverQuality` true. `MaxKeyFrameInterval` is 3600, meaning
effectively no periodic IDRs, since TCP is lossless and keyframes are forced on reconnect
or on a `kf` request.

| Preset   | Capture scale | Bitrate |
|----------|---------------|---------|
| best     | 1.0           | 18 Mbps |
| balanced | 0.75          | 10 Mbps |
| fast     | 0.5           | 6 Mbps  |

Defined at `MacSender.swift:30-50`. Quality presets scale the captured stream, not the
display. Frames drop when `pendingEncodes` or `pendingSends` hit their caps, with a
one-shot replay timer so a static screen does not stay stale (`MacSender.swift:1951`).

## 5. Wire protocol

Framing is `[4-byte big-endian payload length][payload]` in both directions
(`MacSender.swift:2241`, `PROTOCOL.md` section 3). The receiver listens and the sender
dials; the spec calls this its most load-bearing decision, since it makes USB and WiFi
one code path.

**Demux** of the Mac-to-phone direction is a heuristic the spec itself calls design debt:
a payload is JSON control iff length under 32768, first byte `{`, and no NUL byte
(`StreamReceiver.swift:1007`, `PROTOCOL.md` section 4). Annex B start codes guarantee
NULs, which is why it works. A typed header is reserved for pv 4. The rule constrains
sender design: the cursor PNG caps at 24000 bytes pre-base64.

**Video** is Annex B, one access unit per wire frame, always 4-byte start codes, SPS and
PPS prepended to every IDR, no PTS on the wire, optional `{"cap":..,"snd":..}` telemetry
prefix before the first start code.

**Control messages** are JSON keyed on `type`. Phone to Mac: `hello`, `ping`, `touch`,
`scroll`, `pencil`, `proximity`, `kf`, `stats`, `sleeping`, `closing`. Mac to phone:
`pong`, `ping`, `cursor`, `cursorImg`, `welcome`, `updateRequired`. `hello` is mandatory
first and carries panel pixels in current orientation, scale, install `id`, `pv`, and
optionally `cursorPort`, `addrs`, `maxEncodeWide/High`. Rotation is a re-sent `hello`,
debounced 300ms. Mirroring versus extend never crosses the wire; it is purely a
sender-side choice. There is no TLS and no authentication at pv 3.

Two additions: an optional UDP cursor side channel on port+1 with sequence numbers and a
`cursorAck` confirmation, to dodge head-of-line blocking behind large video frames
(`PROTOCOL.md` 6.3, `MacSender.swift:1538`); and a one-way cable upgrade that probes the
receiver's advertised addresses on non-WiFi interfaces and migrates the socket under a
live pipeline without touching the display (`MacSender.swift:1061-1220`).

## 6. Touch input

Coordinates normalise 0..1 against **video** space, not screen space, so letterboxing
stays the receiver's problem. `InputInjector.handleTouch` maps onto
`CGDisplayBounds(displayID)` and posts `leftMouseDown`/`Dragged`/`Up` to
`.cghidEventTap` (`InputInjector.swift:75-114`).

Two hard-won details. The event source must be a real
`CGEventSource(stateID: .hidSystemState)` and `clickState` must be non-zero on down, or
menu tracking breaks and leaves unclickable zombie menu windows composited on the display
(`InputInjector.swift:32-34`). A cancelled touch posts an up with `clickState = 0`, which
keeps button state honest while telling AppKit not to synthesize a click (`:86-105`).

On iOS the mouse-down is withheld until the gesture commits, via 10pt slop and a 120ms
hold timer, because otherwise every second two-finger scroll clicked whatever sat under
the first finger (`OpenSidecarPhoneApp.swift:790-820`). Two-finger pan sends `scroll`
deltas in video pixels with natural-scrolling sign, converted to points by the display
pixel scale before `scrollWheelEvent2` (`:757-780`, `InputInjector.swift:118-127`).

**Apple Pencil** is injected as synthetic *tablet* events, not mouse events: a
`tabletProximity` event with a fabricated vendor ID `0x0D15`, Grip Pen pointer type
`0x0802`, and capability mask `0x05C7`, then mouse events carrying
`mouseEventSubtype = tabletPoint` with pressure, tiltX/Y and rotation
(`InputInjector.swift:177-238`). Because tablet events receive no click state from the
Window Server, double-click counting is reimplemented against
`NSEvent.doubleClickInterval` and `NSDoubleClickDistance`, the latter pulled by `dlsym`
from AppKit (`:14-19`, `:240-276`). UIKit altitude is normalised to a unit tilt vector
rather than passed through as radians (`:282-285`).

## 7. Build and signing

xcodegen from `project.yml`; `DEVELOPMENT_TEAM` comes from the environment so no team ID
is committed. Three app targets: Mac sender (macOS 14+, ScreenCaptureKit floor), Mac
receiver (macOS 12+, reuses `Shared/` unchanged), iOS receiver (16.4+). Debug builds take
their own bundle IDs and product names because TCC keys Screen Recording and Accessibility
grants on bundle ID plus signature, so a shared identifier would void the release app's
grants on every rebuild.

Hardened runtime on, entitlements empty, so the Mac app is **not** sandboxed, which it
cannot be given the usbmuxd socket, `CGEvent` posting, and the private display API.
Distribution is a Developer ID signed and notarized DMG from GitHub Releases,
self-updating via Sparkle 2.x with an EdDSA-signed appcast on `opendisplay.app`. The iOS
app ships via TestFlight. The Mac app cannot go to the App Store because
`CGVirtualDisplay` is private API; the capture and streaming pipeline itself uses only
public API.

## 8. Known weaknesses and hacks

- The demux heuristic constrains every control message (under 32768 bytes, must start
  with `{`, no NUL).
- No authentication and no encryption at pv 3; on WiFi confidentiality rests entirely on
  the link layer.
- HiDPI-mode and mirror-set enforcement loops poll forever at 2s because no event exists
  to hook. Pure workarounds for undocumented WindowServer behavior.
- Poisoned-identity serial bumping is guesswork against saved state nothing can undo.
- Frame drops are unilateral sender-side decisions with no receiver feedback beyond `kf`.
- Pencil barrel roll is wired on the protocol but always 0.
- A device lock occurring after iOS already suspended the app is undetectable, so the
  virtual display lingers.
- `CGVirtualDisplay` is capped at 60Hz and can break on any macOS release.
- The sender keeps streaming after sending `updateRequired` and relies on the receiver to
  block its own UI.

## 9. Licensing: what we can legitimately reuse

GPLv3 bars copying, adapting, or translating this Swift into a proprietary product. Note
that releases up to v0.4.x were MIT and remain available under those terms, which matters
if a permissive base is wanted.

**Free to re-implement** (facts about Apple's APIs, not protected expression):

- The usbmuxd plist protocol, header layout, the network-byte-order `PortNumber` quirk,
  and lockdown big-endian framing. All independently documented by libimobiledevice, so
  cite that rather than this repo.
- The receiver-listens / sender-connects role split.
- Length-prefixed framing; Annex B with SPS and PPS on every IDR.
- The ScreenCaptureKit and VideoToolbox settings (public API values).
- `CGEvent` injection basics.

The private `CGVirtualDisplay` header is itself reverse-engineered from Apple and
published in several projects, so exposure there is Apple private-API risk rather than
this repo's copyright. Do not copy that file; re-derive it from a class dump or from an
earlier MIT-licensed source.

**Expensive to rebuild clean-room** — this is where the engineering budget goes:

1. **Virtual display state management.** Reserve-both-axes, continuous HiDPI
   re-assertion, `.forSession` mirror-break, poisoned-identity fallback. Each is residue
   from one specific field bug. Knowing they exist is most of the value; exact thresholds
   still have to be rediscovered.
2. **Touch-to-click semantics.** The withheld mouse-down, the `clickState = 0` cancel,
   and the non-nil event source with non-zero click state are three separate defects that
   only surface against real AppKit and WebKit behavior.
3. **Pencil as synthetic tablet events.** The proximity handshake and capability mask are
   undocumented; getting Photoshop-class apps to accept a fake tablet takes iteration.
4. **Connection race handling.** Bonjour dialing races IPv4 and IPv6 and both can
   complete; the prove-yourself-with-bytes adoption rule and the dial-generation guards
   were clearly written against production crashes.
5. **Latency tuning.** The 1/120 minimum frame interval, the NV12 end-to-end choice, and
   the low-latency rate control fallback for AMD Macs each carry measured numbers that
   would otherwise have to be re-measured.

**Caution.** `PROTOCOL.md` is part of the GPLv3 repo. Its contents are protocol facts
that may be implemented freely, and the README explicitly invites independent
implementations, but its prose must not be pasted into our own documentation.
