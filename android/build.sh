#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/android"
T="$B/trime"
TRIME_TAG=v3.3.13
APK_NAME=com.osfans.trime-v3.3.13-0-gb5cad1a4-arm64-v8a-release.apk
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"

"$ROOT/scripts/rime_data.sh"
mkdir -p "$ROOT/build/dl"
APK="$ROOT/build/dl/$APK_NAME"
[ -f "$APK" ] || curl -fL -o "$APK" "https://github.com/osfans/trime/releases/download/$TRIME_TAG/$APK_NAME"

rm -rf "$T"
git clone --depth 1 -b "$TRIME_TAG" https://github.com/osfans/trime.git "$T"

rm -rf "$B/apk" && mkdir -p "$B/apk"
unzip -q -o "$APK" 'lib/*' 'assets/shared/*' -d "$B/apk"
mkdir -p "$T/app/prebuilt"
cp -R "$B/apk/lib/arm64-v8a" "$T/app/prebuilt/"

SHARED="$T/app/src/main/assets/shared"
find "$SHARED" -maxdepth 1 -type l -delete
for f in key_bindings.yaml punctuation.yaml symbols.yaml; do cp "$B/apk/assets/shared/$f" "$SHARED/"; done
cp -R "$B/apk/assets/shared/opencc" "$SHARED/"
rsync -a --exclude 'squirrel.yaml' --exclude 'weasel.yaml' --exclude 'LICENSE' "$ROOT/build/rime-data/" "$SHARED/"

PRE="$B/prebuild"
rm -rf "$PRE" && mkdir -p "$PRE"
clang -O1 -I/opt/homebrew/opt/librime/include -L/opt/homebrew/opt/librime/lib -lrime \
  "$ROOT/tests/rime/harness.c" -o "$ROOT/build/rime_harness"
echo | "$ROOT/build/rime_harness" "$ROOT/build/rime-data" "$PRE" "$PRE/build" deploy
mkdir -p "$SHARED/build"
cp "$PRE"/build/*.bin "$SHARED/build/"

python3 "$ROOT/android/patch.py" "$T" "$(cat "$ROOT/VERSION")"
rsync -a "$ROOT/android/overlay/" "$T/"

SIGN="$ROOT/android/signing"
if [ ! -f "$SIGN/qi.jks" ]; then
  mkdir -p "$SIGN"
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$SIGN/qi.jks" -alias qi -keyalg RSA -keysize 3072 \
    -validity 36500 -storepass qi-input -keypass qi-input -dname "CN=Qi"
fi
printf 'storeFile=%s\nstorePassword=qi-input\nkeyAlias=qi\nkeyPassword=qi-input\n' "$SIGN/qi.jks" > "$B/keystore.properties"

cd "$T"
./gradlew --no-daemon -PbuildABI=arm64-v8a -PkeystoreProperties="$B/keystore.properties" \
  -PbuildVersionName="$(cat "$ROOT/VERSION")" assembleRelease
mkdir -p "$ROOT/dist"
cp "$(ls app/build/outputs/apk/release/*.apk | head -1)" "$ROOT/dist/YiQi-Android.apk"
echo "$ROOT/dist/YiQi-Android.apk"
