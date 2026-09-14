# Tandem — product & engineering plan

Working title **Tandem** (rename before launch; check trademarks). One Mac
host app turns iPhones, iPads and Android phones/tablets into real extended
displays over **USB (primary)** and **WiFi (secondary)**.

## 1. Positioning

| | Tandem | Sidecar | Duet | Side Screen | OpenDisplay | BetterCast |
|---|---|---|---|---|---|---|
| Android USB | ✅ | ✗ | ✅ (sub) | ✅ | ✗ | ✅ (ADB) |
| iPhone/iPad USB | ✅ | iPad only | ✅ (sub) | ✗ | ✅ | ✗ |
| WiFi | ✅ encrypted | ✅ | ✅ | ✅ (no TLS) | ✅ (no auth) | ✅ (no TLS) |
| Multi‑device | ✅ | ✗ | ✅ | ✗ | ✗ | ✅ |
| Price | one‑time | free | subscription | free/OSS | free/OSS | free/OSS |
| Notarized, updates, support | ✅ | – | ✅ | ✗ | ✗ | partial |

Selling points: one app for every phone/tablet you own, cable‑first latency,
encrypted WiFi with PIN pairing, no account, one‑time purchase, polished
onboarding (permissions, adb, trust prompts), Korean/English/Japanese UI.

## 2. Licensing of reused code

* **SideScreen (MIT)** — reuse allowed with attribution. Reused/adapted:
  `CGVirtualDisplayBridge.h`, `VirtualDisplayManager`, `ScreenCapture`
  (SCStream + CGDisplayStream fallback), `VideoEncoder` (VideoToolbox
  HEVC/H.264 Annex‑B), Android `VideoDecoder`/`CodecCapabilities`. Keep the
  MIT notice in `THIRD_PARTY_NOTICES.md`.
* **OpenDisplay (GPLv3)** and **BetterCast (GPLv3)** — **no code copied**.
  Techniques re‑implemented from public knowledge: usbmuxd plist protocol
  (documented by libimobiledevice), receiver‑listens role assignment,
  AVSampleBufferDisplayLayer rendering, AWDL via `includePeerToPeer`.
* Bundled `adb` (Apache‑2.0 from Android platform‑tools) — include the notice.
* Sparkle (MIT) for updates.

## 3. Architecture

```
tandem/
  docs/PROTOCOL.md          wire contract (pv 1)
  Shared/TandemProtocol/    SwiftPM library: framing, messages, crypto, FrameCodec (macOS + iOS)
  MacHost/                  xcodegen project → Tandem.app (macOS 14+, LSUIElement menu bar app)
    Sources/App             SwiftUI MenuBarExtra, Settings, Onboarding, Pairing sheet
    Sources/Display         CGVirtualDisplay bridge (MIT, SideScreen)
    Sources/Capture         ScreenCaptureKit capturer
    Sources/Encode          VideoToolbox encoder
    Sources/Input           CGEvent injector (touch→mouse, scroll, keys)
    Sources/Transport       UsbmuxClient, AdbBridge (bundled adb), LanBrowser (NWBrowser + P2P), Dialer
    Sources/Session         DisplaySession (VD+capture+encode+conn), SessionManager (multi)
    Sources/Licensing       Ed25519 license keys, 7‑day trial, Keychain
    Resources/              adb binary, icons, Localizable (en/ko/ja)
  Receivers/iOS/            xcodegen → Tandem.app (iOS 16+), NWListener 41777 + Bonjour, AVSampleBufferDisplayLayer, touch/pencil/keyboard
  Receivers/Android/        Gradle → Tandem (minSdk 26), ServerSocket 41777 + NsdManager, MediaCodec→SurfaceView, touch/stylus/keyboard
  scripts/                  build_mac.sh (archive, Developer ID sign, notarize, DMG, appcast)
```

Key runtime rules
* **Receiver listens, host dials** (see PROTOCOL §1). Host owns discovery.
* One `DisplaySession` per receiver: own virtual display, own SCStream, own
  encoder, own connection. Sessions are independent; a device unplug tears
  down only its session.
* Host keeps a physical display as main whenever one exists (SideScreen #39).
* USB Android: Tandem ships `adb`, runs its own server on a private port
  (`adb -P 5137`) to not fight Android Studio, watches `track-devices`.
* USB iOS: `UsbmuxClient` speaks the plist protocol on `/var/run/usbmuxd`
  (`Listen` for attach/detach, `Connect` to 41777). Device name via lockdown
  `GetValue DeviceName` (no pairing session needed).
* WiFi: `NWBrowser(_tandem._tcp)` with `includePeerToPeer = true` (AWDL for
  Apple receivers), PIN pairing, AES‑GCM envelope.

## 4. Milestones

| # | Milestone | Definition of done |
|---|-----------|--------------------|
| M1 | **Wired MVP** | Mac host + iOS + Android receivers build; iPhone over USB and Android over USB show an extended display with touch; HEVC 60 fps; reconnect on replug. |
| M2 | **WiFi** | Bonjour discovery, PIN pairing, encrypted stream, paired‑device list, AWDL for iOS. |
| M3 | **Product polish** | Onboarding (Screen Recording, Accessibility, adb/USB debugging, Trust prompt), settings (quality, fps, HiDPI, rotation, mirror), multi‑device, headless/login item, Sparkle updates, ko/en/ja. |
| M4 | **Commerce** | License keys (Ed25519, offline), 7‑day trial, purchase via Lemon Squeezy/Paddle, website, notarized DMG, App Store (iOS) & Play (Android) receivers. |
| M5 | **Beta → 1.0** | TestFlight/closed testing, crash‑free 99.5 %, latency budget: USB < 20 ms glass‑to‑glass on M‑series, WiFi < 40 ms on 5 GHz. |

## 5. Risks

* `CGVirtualDisplay` is private API → Mac app cannot ship on the Mac App
  Store; direct sale only (same as BetterDisplay/DeskPad/OpenDisplay).
  Notarization does not scan for private API use.
* Android USB requires USB debugging. Mitigation: guided onboarding; v2
  explores AOA (Android Open Accessory) via IOUSBHost to drop adb entirely.
* iOS App Review needs to see the receiver working: provide a demo video and
  a review note; keep the receiver free.
* macOS 15+ Local Network privacy prompt for Bonjour browsing; explain in
  onboarding.
