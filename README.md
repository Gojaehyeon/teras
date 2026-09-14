# Teras

Turn the phones and tablets you already own — iPhone, iPad, Android — into
real extended displays for your Mac. Cable first (USB‑C / Lightning, lowest
latency), WiFi second (PIN‑paired, encrypted).

* `docs/PROTOCOL.md` — the wire contract every peer implements.
* `docs/PLAN.md` — positioning, architecture, milestones, risks.
* `docs/VECTORS.md` — crypto interop vectors shared by all implementations.
* `Shared/TerasProtocol` — Swift package (framing, messages, crypto) used by the Mac host and the iOS receiver.
* `MacHost` — macOS menu‑bar host app (xcodegen).
* `Receivers/iOS` — iPhone/iPad receiver (xcodegen).
* `Receivers/Android` — Android receiver (Gradle).

## Build

```sh
# shared package
cd Shared/TerasProtocol && swift test

# Mac host
cd MacHost && xcodegen generate && xcodebuild -scheme Teras -configuration Debug -derivedDataPath build build

# iOS receiver
cd Receivers/iOS && xcodegen generate && xcodebuild -scheme TerasReceiver -destination 'generic/platform=iOS Simulator' -derivedDataPath build build

# Android receiver
cd Receivers/Android && ./gradlew assembleDebug
```

Third‑party code and licenses: see `THIRD_PARTY_NOTICES.md`.
