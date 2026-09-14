#!/usr/bin/env bash
# Generate Tandem.xcodeproj and build it into ./build.
#
# Usage: scripts/build.sh [Debug|Release] [build|test|clean]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-Debug}"
ACTION="${2:-build}"
DERIVED="$ROOT/build"

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "==> xcodegen generate"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" xcodegen generate --quiet

# Without a team we cannot use automatic signing, so fall back to an ad-hoc
# signature. The app still gets its entitlements and hardened runtime, which is
# all a local run needs; Developer ID signing happens in the release pipeline.
SIGN_ARGS=()
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  echo "==> DEVELOPMENT_TEAM is empty: building with an ad-hoc signature"
fi

case "$ACTION" in
  clean)
    xcodebuild -project Tandem.xcodeproj -scheme Tandem -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED" clean
    ;;
  test)
    xcodebuild -project Tandem.xcodeproj -scheme Tandem -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
      "${SIGN_ARGS[@]}" test
    ;;
  build)
    xcodebuild -project Tandem.xcodeproj -scheme Tandem -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build
    echo "==> built: $DERIVED/Build/Products/$CONFIG/Tandem.app"
    ;;
  *)
    echo "unknown action: $ACTION (build|test|clean)" >&2
    exit 2
    ;;
esac
