#!/usr/bin/env bash
# Builds the Teras control server into a single dex jar and installs it into
# MacHost/Resources so the Mac app can push it to /data/local/tmp.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
COMPILE_SDK="${COMPILE_SDK:-35}"
BUILD_TOOLS="${BUILD_TOOLS:-35.0.0}"
MIN_API="${MIN_API:-26}"

if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
JAR="$JAVA_HOME/bin/jar"

android_jar="$ANDROID_HOME/platforms/android-$COMPILE_SDK/android.jar"
d8_jar="$ANDROID_HOME/build-tools/$BUILD_TOOLS/lib/d8.jar"

for required in "$JAVAC" "$JAVA" "$JAR" "$android_jar" "$d8_jar"; do
  if [[ ! -e "$required" ]]; then
    echo "build.sh: missing $required" >&2
    echo "  set ANDROID_HOME / JAVA_HOME / COMPILE_SDK / BUILD_TOOLS to override" >&2
    exit 1
  fi
done

build="$here/build"
classes="$build/classes"
test_classes="$build/test-classes"
dex="$build/dex"
jar_out="$build/teras-control.jar"
resources_jar="$repo_root/MacHost/Resources/teras-control.jar"

rm -rf "$build"
mkdir -p "$classes" "$test_classes" "$dex"

echo "==> javac (release 17, against android-$COMPILE_SDK)"
find "$here/src" -name '*.java' >"$build/sources.txt"
"$JAVAC" --release 17 -Xlint:all -encoding UTF-8 \
  -cp "$android_jar" -d "$classes" "@$build/sources.txt"

echo "==> unit test (desktop JVM, no Android)"
# Framing is Android-free on purpose, so it compiles and runs on the plain JDK.
"$JAVAC" --release 17 -encoding UTF-8 -d "$test_classes" \
  "$here/src/app/teras/control/Framing.java" \
  "$here/test/app/teras/control/FramingTest.java"
"$JAVA" -cp "$test_classes" app.teras.control.FramingTest

echo "==> d8 (min-api $MIN_API)"
find "$classes" -name '*.class' >"$build/classes.txt"
# Invoked through $JAVA rather than the build-tools d8 wrapper, which needs a
# `java` on PATH that a plain macOS shell does not have.
"$JAVA" -cp "$d8_jar" com.android.tools.r8.D8 \
  --release --min-api "$MIN_API" --lib "$android_jar" --output "$dex" \
  @"$build/classes.txt"

echo "==> package $jar_out"
rm -f "$jar_out"
"$JAR" --create --no-manifest --file "$jar_out" -C "$dex" classes.dex

mkdir -p "$(dirname "$resources_jar")"
cp "$jar_out" "$resources_jar"

echo "==> done"
ls -l "$jar_out" "$resources_jar"
