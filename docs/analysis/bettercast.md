# BetterCast — Technical Report

Root: `/Users/go/lab/ref/BetterCast`. All paths below are relative to it. GPLv3. Mac app v21.0, iOS 1.4 (build 20), Android 1.3 (versionCode 4). Git history squashed to one commit.

## 1. Multi-receiver architecture

One `ConnectionPipeline` per receiver in a `[UUID: ConnectionPipeline]` dict on `NetworkClient` (`Sources/BetterCastSender/BetterCastSenderApp.swift:2853`, dict at `:2899`). Each owns its own `VirtualDisplayManager`, `ScreenRecorder`, `VideoEncoder`, `AudioEncoder`, plus link flags `isP2P`, `isLoopback`, `isWiFiADB`, `forceTCP`, `supportsTypeByte`. Adaptive state was deliberately hoisted onto the encoder class because mutating the dict from the encoder callback thread corrupted the heap (`:2890`).

Displays use the **private CoreGraphics `CGVirtualDisplay` API** via class-dumped headers and an Objective-C shim (`Sources/BetterCastSender/VirtualDisplay/VirtualDisplay.m:25`).

Best idea here: `VirtualDisplayManager.swift:54-98` derives a **stable serial per device** (FNV-1a over service name, persisted in `UserDefaults`). macOS keys saved arrangement on vendor/product/serial, so the same iPhone reappears in the same slot. A counter does not, and one connect burns two serials since the display is rebuilt after the device reports its true size.

UI: `SidebarView:771`, `SidebarDeviceRow:996`, `DeviceDetailView:2216`, `DisplayOverviewView:1814` (live thumbnails, drag-to-arrange).

## 2. Transports

| Port | Role |
|---|---|
| TCP 51820 | Primary stream |
| UDP 51821 | Chunked frames (Mac constant) |
| TCP 51822 | Sender invite, `_bettercast-sender._tcp` |
| TCP 51823 | `adb forward` host side |
| TCP 51824 | usbmux loopback |

`Sources/BetterCastSender/Constants.swift:29-56`.

**mDNS.** `NWBrowser` on `_bettercast._tcp`/`_udp`. `DiscoveredService` carries a sticky `seenOnAWDL` flag (`:2811-2817`) so a forced P2P dial is never attempted at a device that never answers on awdl0 — that cost two five-second timeouts per Android connect.

**AWDL.** Network.framework, not raw Bonjour: `includePeerToPeer = true` plus pinning `requiredInterface` to awdl0/llw (`ReceiverNetworkListener.swift:320,359`; `Sources/BetterCastReceiverIOS/NetworkListenerIOS.swift:133,183-192`). The non-obvious part: `NWPathMonitor` never reports awdl0 in `availableInterfaces`, so the interface is harvested out of browse results (`BetterCastSenderApp.swift:3197-3206`). iOS falls back to default routing after 4s (`NetworkListenerIOS.swift:211-226`).

**ADB.** Four paths probed (`ReceiverNetworkListener.swift:100-108`), then `adb forward tcp:51823 tcp:51820`; `adb tcpip 5555` for wireless handoff after a 5s delay (`:199-240`). The desktop receiver has its own `AdbHelper.cpp` bridge (local port = remote+1).

**iPhone USB: implemented, definitively.** `Sources/BetterCastSender/Usbmux.swift` speaks the usbmuxd plist protocol directly on `/var/run/usbmuxd`. No libimobiledevice, no `iproxy`, no peertalk anywhere. `ListDevices` filters `ConnectionType == "USB"` (`:156`); `Connect` passes the port byte-swapped inside the plist (`:168`). `UsbmuxTunnel.swift` listens on 127.0.0.1:51824 and pumps bytes, so the transport above never learns it is on a cable. The README table, which lists wired USB as Android-only, is wrong.

**Port inconsistency worth knowing.** The Mac defines `udpPort = 51821` (`Constants.swift:32`), but the Android receiver runs UDP on its TCP port — `UdpClient.kt:24` defaults to 51820 and is constructed with `tcpServer.listeningPort` (`ReceiverViewModel.kt:184,196`). 51821 appears nowhere in the Android tree.

**Wire format.** `[u32 BE len][1B type][payload]`, type 0x01 video / 0x02 AAC, AVCC/HVCC length-prefixed. Legacy senders omit the type byte; receivers sniff the first frame (`NetworkListener.cpp:174-206`).

## 3. Video pipeline

ScreenCaptureKit, one `SCStream` per pipeline against that pipeline's virtual display, with a 2s retry loop because the display takes time to appear (`ScreenRecorder.swift:50-65`). A second path via `CGDisplayStream` (`LegacyDisplayCapture.swift`) exists to bypass SCK's DRM/HDCP blanking, overridable per device (`BetterCastSenderApp.swift:3067-3074`).

`VTCompressionSession` with RealTime on, reordering off, `DataRateLimits` always applied with a tunable `burstMultiplier` (`VideoEncoder.swift:108-131`). With `AverageBitRate` alone a 20 Mbps target measured 54 Mbps (`:187`).

Codec: global picker plus **per-device override keyed by service name** (`:3046-3059`), because flipping the global to HEVC silently blanked iPhone and Mac receivers. Auto-promotes H.264 to HEVC above 4096 pixels, since Apple's H.264 encoder tops out there and 5K is the headline case (`:5973-5979`).

Per-link profiles (`:5896-5970`):

| Link | FPS | Bitrate | Keyframe |
|---|---|---|---|
| AWDL P2P | 60 | selected | 10s |
| USB cable iOS | 60 | <=25 Mbps | 3s |
| USB ADB | 60 | selected | 10s |
| WiFi ADB | 60 | <=10 Mbps | 3s |
| Infrastructure | 30 | ceiling | 1s |

30fps on infrastructure is measured, not guessed: at 60 the 16.7ms send window is missed often enough that dropped P-frames force near-continuous recovery keyframes. Rate-limit windows: 0.1s P2P, 0.25s WiFi ADB, 1.0s otherwise.

Two mechanisms worth taking conceptually. **Adaptive bitrate** driven by backpressure drops, hysteresis, 2 Mbps floor. **Shared radio budget** (`:5363-5420`): all wireless receivers share one Wi-Fi chip including AWDL, so each ceiling is total budget minus others' measured use, clamped to fair share; a starved neighbour is credited fair share rather than its measured rate, which stops a documented spiral where an iPhone climbed to 27 Mbps while an Android sat at 2.5 Mbps and 1-6 fps.

Audio: AAC-LC 48 kHz stereo 128 kbps via `AudioConverter`, 1024-frame accumulator (`AudioEncoder.swift`, `Constants.swift:58-69`). Video frames carry an 8-byte PTS; audio does not. There is no A/V sync mechanism — audio plays as it arrives, and on Android it is TCP-only (`TcpClient.kt:217-225`).

## 4. Input back to the Mac

`InputEvent` is `Codable`: normalized 0-1 coords, dedup `eventId`, `clickCount`, and Pencil `pressure`/`altitude`/`azimuth` — presence of `pressure` marks an event as stylus, so older receivers degrade gracefully (`Sources/BetterCastSender/InputEvent.swift:15-46`). Length-prefixed JSON; critical events sent 3x. Command type 99 carries control in-band: 770 device hello, 777 screen dims, 888 heartbeat.

`InputHandler` posts `CGEvent`s against a per-connection display bounds map and releases latched buttons and stylus proximity when a device vanishes mid-drag (`InputHandler.swift:16-53`). Accessibility via `AXIsProcessTrustedWithOptions` (`:57`), with a `tccutil reset` escape hatch (`BetterCastSenderApp.swift:5001-5033`).

Receivers map gestures locally: three-finger swipe to Mission Control, pinch to magnify, two-finger tap to right-click (`VideoRendererViewIOS.swift:129-190`; `input/TouchHandler.kt:89-273`). The desktop receiver maps Qt keys through a hardcoded Qt-to-macOS `CGKeyCode` table because the wire protocol always expects macOS keycodes (`InputHandler.cpp:79-127`).

## 5. Windows sender (beta)

C++/Qt6, opt-in via `option(ENABLE_SENDER OFF)` (`CMakeLists.txt:25`). DXGI Desktop Duplication with a GDI BitBlt fallback for virtual displays, CPU fixed-point BGRA-to-NV12 (`sender/ScreenCaptureWin.cpp:100,282,240-266`). FFmpeg encode probing NVENC, AMF, QSV, VAAPI, libx264 (`sender/VideoEncoderFF.cpp:122-135`); the VAAPI path is a stub with `hw_device_ctx` init "skipped for now" (`:66-70`). H.264 only.

They **do** ship the virtual display driver. `installer.nsi:216-224` bundles itsmikethetech's Virtual Display Driver (`MttVDD.inf`, formerly IddSampleDriver) and installs it elevated via `pnputil /add-driver` plus `devcon install Root\MttVDD`. `sender/VirtualDisplayVDD.cpp` (939 lines) then controls it unelevated over named pipe `\\.\pipe\VDDPipe` with JSON add/remove commands, falling back to editing a settings XML. The elevation split is a documented wart: no in-app repair if the driver breaks post-install.

Single stream only — `SenderController` holds exactly one capture, encoder, and sender (`sender/SenderController.cpp:12-163`). Monitor choice is a dropdown, one target at a time. Non-Windows errors out at `:49-53`. Linux capture is a PipeWire TODO (`CMakeLists.txt:162`).

## 6. Android receiver

Kotlin/Compose, `com.bettercast.receiver`, minSdk 26, targetSdk 34.

`video/VideoDecoder.kt` sniffs H.264 vs HEVC from NALU bytes **every frame**, not once, to avoid a stale-codec black screen (`:127-162`). Low latency pursued three ways: `KEY_LOW_LATENCY` + `KEY_PRIORITY=0` + `KEY_OPERATING_RATE=Short.MAX_VALUE`, vendor keys `vendor.low-latency.enable` and the Qualcomm `vendor.qti-ext-dec-*` pair, and a `MediaCodecList` scan preferring a `.low_latency` hardware variant (`:296-327`). Credited to Moonlight. H.264 gets a real SPS parser (`video/SpsParser.kt`); **HEVC has none** and guesses 1920x1080 until MediaCodec corrects it (`:250-260`).

The foreground service is for Android-as-**sender** only (`sender/ScreenCaptureService.kt:38`, `mediaProjection` type). The receiver has no service and no wake lock — only `FLAG_KEEP_SCREEN_ON` (`MainActivity.kt:77`), which dies when backgrounded. Android also ships a full undocumented sender path (`sender/VideoEncoder.kt`, H.264 only).

USB vs Wi-Fi is invisible to Android: the Mac drives adb, the client just dials 51820. **Keyboard input is defined but never produced** — `TYPE_KEY_DOWN/UP` exist (`input/InputEvent.kt:22-23`) with nothing constructing them.

## 7. iOS receiver

`VTDecompressionSession` into `AVSampleBufferDisplayLayer`, with `DisplayImmediately` forced per sample to stop queue buildup (`VideoDecoder.swift:13`; `VideoRendererViewIOS.swift:64-70,110-114`). Codec sniffed per-NALU so a mid-session switch reconfigures (`:29-95`). Presentation time is host clock + 16ms, cut down from 50ms (`:233-236`). Full-rate drag sampling bypasses UIKit's per-frame callback using coalesced touches (`VideoRendererViewIOS.swift:192-238`).

Two TCP listeners: fixed 51820 for Wi-Fi, dynamic-port AWDL listener for Apple-to-Apple (`NetworkListenerIOS.swift:300-363`). The invite flow browses `_bettercast-sender._tcp` and resolves the port through Bonjour rather than hardcoding 51822.

**No background streaming.** No `UIBackgroundModes`, no lifecycle handlers at all; only `isIdleTimerDisabled = true` (`ViewController.swift:67`).

Bundle `com.bettercast.receiver.ios`, App Store id 6761002383, withheld in the EU pending trader verification. `MinimumOSVersion` 15.0 despite `Package.swift` claiming 13. `UIRequiredDeviceCapabilities` still lists `armv7`. `BCTabBarController.swift:57-59` force-selects the Setup tab with a `SCREENSHOT` comment — leftover automation state shipping in production.

## 8. Build and packaging

`make_app.sh` hand-assembles the bundle with no Xcode project: universal `swift build`, copy plist/icns/`localization/*.lproj`, `codesign --deep --options runtime` with Developer ID, writable DMG, AppleScript Finder layout, UDZO convert, sign, `notarytool submit --wait` + `stapler`. `VERSION="v21"` is echoed but never injected into any plist.

`package_ios_ipa.sh` is the rough one: hardcoded DerivedData path for a specific user account (`:8`), manual bundling of 18 `libswift*.dylib`, `zip -r` of `Payload`, **no codesigning** — it targets Sideloadly, not the App Store.

`fastlane/` has `Appfile`/`Fastfile`/`Snapfile` with `screenshots` and `build` (gym) lanes; no `metadata/`, listing copy sits in `screenshots/ios/APP_STORE_LISTING.txt`. `.github/workflows/` covers only Linux and Windows receivers — **macOS and iOS have no CI**, built locally by shell script. Six localizations (en, zh-Hans, ja, ko, de, fr) through a custom `tr()` helper (`Constants.swift:15`). `LegacyMacReceiver/` targets macOS 10.15-12.

## 9. Product and UX features

Auto-connect on discovery. Per-device overrides for codec, compatibility mode, brightness, audio, smooth motion. Five bitrate presets (5-100 Mbps), eight resolution presets including 5K Retina HiDPI. Frame rate override. Arrangement memory across reconnects. Hotspot pairing by scanning a Wi-Fi QR off the phone (`HotspotQRScanner.swift`), with the Android side able to raise a local-only hotspot (`network/HotspotManager.kt:26-60`). Manual IP entry, ADB connect row, 7-step spotlight tour, GitHub Releases update check, Report Issue with logs pre-filled, live thumbnails with drag-arrange, per-second pipeline stats deliberately formatted to match SideScreen's, inbound invite approval, permission reset.

No headless mode. No authentication.

## 10. Weaknesses and hacks

- **Private, undocumented CoreGraphics API** underpins the whole Mac product. Breaks on any macOS release; rules out the App Store.
- **No encryption, no authentication on the wire.** Any LAN peer speaking the framing connects. Invite approval covers inbound only; the stream is plaintext.
- Desktop receiver decodes **software H.264 only** — `avcodec_find_decoder(AV_CODEC_ID_H264)` with no hwaccel context (`VideoDecoder.cpp`). Advertised HEVC never reaches Windows or Linux, and decode is CPU-bound.
- 739-line hand-rolled mDNS responder duplicating Bonjour/Avahi (`ServiceDiscovery.cpp:250-739`).
- VDD control blocks the GUI thread with `QThread::msleep(1000-2000)` inside display creation.
- Android input injection shells out to `adb shell input` per event.
- Android TCP desync: an invalid frame length `continue`s instead of resyncing (`TcpClient.kt:194-198`). `minifyEnabled=false` in release (`app/build.gradle.kts:43`).
- `BetterCastSenderApp.swift` is 6,323 lines.
- Hardcoded adb paths; hardcoded DerivedData path; unsigned IPA script; `armv7` capability on a 64-bit app; `Package.swift` and `Info.plist` disagree on minimum iOS.

## 11. Licensing

GPLv3 and viral. Nothing under `Sources/` goes into a proprietary product.

**Safe to re-implement independently** (ideas and protocols are not copyrightable): the usbmuxd plist protocol, which is Apple-defined and publicly documented; the loopback-tunnel pattern hiding both usbmuxd and adb behind 127.0.0.1; `includePeerToPeer` plus awdl0 interface pinning; harvesting AWDL from browse results; one virtual display per receiver with a stable hashed serial; the per-link quality profiles and the reasoning for 30fps on infrastructure; the shared-radio budget with starved-neighbour crediting; HEVC promotion above 4096; per-device codec override as a safety valve; DXGI duplication; codec sniffing from NALU headers.

**Avoid.** Any BetterCast source, comments, or log format — the per-second stats format is itself copied from SideScreen. The Android vendor low-latency keys are credited to Moonlight (GPL-3.0); source them from vendor docs or AOSP.

**Two third-party dependencies to check separately.** `Sources/BetterCastSender/VirtualDisplay/` is *not* GPLv3: `VirtualDisplay.m`/`.h` carry an Apache-2.0 header with no named copyright holder, and the four `CGVirtualDisplay*.h` files are class-dump output of Apple's private framework. Apache-2.0 would permit proprietary reuse, but the unnamed holder and the separate question of Apple's terms both need counsel. Second, the Windows installer redistributes itsmikethetech's Virtual Display Driver — verify that driver's own license before shipping anything similar.
