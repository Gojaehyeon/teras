#!/usr/bin/env bash
# Archive, Developer ID-sign, notarize, staple and package Teras.app into a DMG.
#
# Prerequisites (one time):
#   xcrun notarytool store-credentials teras-notary --apple-id <apple id> --team-id <TEAM> --password <app-specific pw>
#   export DEVELOPMENT_TEAM=<TEAM>          # e.g. RP5GZ99V95
# Usage: scripts/release_mac.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/MacHost"

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)}"
PROFILE="${NOTARY_PROFILE:-teras-notary}"
OUT="$ROOT/dist"; mkdir -p "$OUT"
ARCHIVE="$OUT/Teras.xcarchive"
EXPORT="$OUT/export"

xcodegen generate
xcodebuild -scheme Teras -configuration Release -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" MARKETING_VERSION="$VERSION" \
  archive | tail -3

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" | tail -3
APP="$EXPORT/Teras.app"

# Notarize the app (zip), staple, then build the DMG and notarize that too.
ditto -c -k --keepParent "$APP" "$OUT/Teras.zip"
xcrun notarytool submit "$OUT/Teras.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

DMG="$OUT/Teras-$VERSION.dmg"
rm -f "$DMG"
STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Teras" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "✅ $DMG"
