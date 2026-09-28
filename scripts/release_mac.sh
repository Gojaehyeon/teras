#!/usr/bin/env bash
# Archive, Developer ID-sign, notarize, staple and package Teras.app into a DMG.
#
# Notarization uses an App Store Connect API key:
#   ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (a .p8) must be set, or a
#   notarytool keychain profile named $NOTARY_PROFILE (default teras-notary).
# The adb binary is bundled from ADB_SOURCE (default: Homebrew platform-tools).
# Usage: scripts/release_mac.sh <marketing version> <build number>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/MacHost"

: "${DEVELOPMENT_TEAM:=RP5GZ99V95}"
VERSION="${1:?marketing version, e.g. 1.0.0}"
BUILD="${2:?build number, e.g. 1}"
ADB_SOURCE="${ADB_SOURCE:-/opt/homebrew/bin/adb}"
SIGN_ID="Developer ID Application"
OUT="$ROOT/dist"; mkdir -p "$OUT"
ARCHIVE="$OUT/Teras.xcarchive"
EXPORT="$OUT/export"
NOTARY_ARGS=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-teras-notary}")
fi

echo "▶ archive $VERSION ($BUILD)"
xcodegen generate >/dev/null
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -scheme Teras -configuration Release -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ONLY_ACTIVE_ARCH=NO archive 2>&1 | grep -E "error:|ARCHIVE" | tail -3

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
echo "▶ export (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" 2>&1 | grep -E "error:|EXPORT" | tail -3
APP="$EXPORT/Teras.app"

echo "▶ bundle adb from $ADB_SOURCE"
ENT="$OUT/Teras.entitlements"
codesign -d --entitlements :- "$APP" > "$ENT" 2>/dev/null || true
cp "$ADB_SOURCE" "$APP/Contents/Resources/adb"
chmod 755 "$APP/Contents/Resources/adb"
# Nested executables must carry their own Developer ID signature with the
# hardened runtime, otherwise notarization rejects the bundle.
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/adb"
# Re-seal the outer bundle so its resource hashes include adb.
if [[ -s "$ENT" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/Teras"

echo "▶ notarize app"
ditto -c -k --keepParent "$APP" "$OUT/Teras.zip"
xcrun notarytool submit "$OUT/Teras.zip" "${NOTARY_ARGS[@]}" --wait 2>&1 | grep -E "id:|status:" | tail -2
xcrun stapler staple "$APP" | tail -1

DMG="$OUT/Teras-$VERSION.dmg"
echo "▶ dmg $DMG"
rm -f "$DMG"
STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Teras" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$SIGN_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | grep -E "id:|status:" | tail -2
xcrun stapler staple "$DMG" | tail -1
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
spctl -a -t exec -vv "$APP" 2>&1 | tail -2

echo "▶ result"
ls -la "$DMG" | awk '{print "size", $5}'
shasum -a 256 "$DMG"
