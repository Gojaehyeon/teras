# Teras 1.0.0 — release record (2026-09-28)

## Mac host (paid)
- Build: `Teras.app` 1.0.0 (build 1), universal (x86_64 + arm64), macOS 14.0+.
- Signing: Developer ID Application: Jahyeon Ko (RP5GZ99V95), hardened runtime, timestamped.
- Bundled `adb` (Android platform-tools 37.0.1, Apache-2.0, see THIRD_PARTY_NOTICES.md) signed separately with the same identity.
- Notarization (App Store Connect API key 7QK9US4Q57):
  - app zip submission `89a774ce-57be-4cd3-aebf-78c945087396` — Accepted, stapled
  - DMG submission `bd9080ed-19ed-4e7a-baf7-c85aa882aacf` — Accepted, stapled
- Gatekeeper: `spctl -a -t open` on the DMG and `spctl -a -t exec` on the app both report `Notarized Developer ID`.
- Artifact: `dist/Teras-1.0.0.dmg` (git-ignored)
  - size 9,899,500 bytes
  - SHA-256 `8d63bb7d4c15d1ee7da6c9cd672d46dedcfbaacf66922ad34c24b499d7057947`
  - stored privately at Supabase bucket `shop-files` → `software/teras/Teras-1.0.0.dmg` (served only through the shop's paid-order download route).
- Reproduce: `ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… scripts/release_mac.sh 1.0.0 1`

## Android receiver (free)
- `Teras-Receiver-Android-1.0.0.apk`, versionCode 1, minSdk 26, R8 minified.
- Signed with the Teras release key (`~/.teras-signing/teras-release.jks`, NOT in git; back it up — a lost key means a new package identity on Google Play).
  Certificate SHA-256 `95130cf48fa07a8d3b935592d6b594186bfc2a5473678eca2993d43999d9996d`.
- SHA-256 `14faeb4386e0e7a2c62c0557a90d41f7be933fe7a1f535c52ed4b6fcac0b0ddf`, 1,200,949 bytes (rebuilt with the app icon; release asset replaced).
- Public download: https://github.com/Gojaehyeon/teras/releases/download/v1.0.0/Teras-Receiver-Android-1.0.0.apk

## iOS receiver (free)
- Built and verified on device with a development profile only. No App Store Connect app record, no TestFlight build yet → not publicly installable.

## Verified on real hardware (2026-09-15 … 09-25)
- Samsung Galaxy Z Fold (SM-F971N) over USB: extended display 2448×1848 HiDPI, HEVC 60 fps; auto-reconnect after replug/app reinstall (~2 s).
- iPhone 17 over USB (usbmuxd) and iPhone 18 Pro / iPhone SE 3 over USB & WiFi (PIN pairing): extended display, HEVC 60 fps.
- Screen Recording permission missing → host refuses to dial (no display flicker).
