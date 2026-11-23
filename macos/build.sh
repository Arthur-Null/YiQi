#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/macos"
SQUIRREL_PKG="$ROOT/build/dl/Squirrel-1.1.2.pkg"
"$ROOT/scripts/rime_data.sh" >/dev/null
[ -f "$SQUIRREL_PKG" ] || { mkdir -p "$ROOT/build/dl"; curl -fL -o "$SQUIRREL_PKG" https://github.com/rime/squirrel/releases/download/1.1.2/Squirrel-1.1.2.pkg; }

rm -rf "$B"; mkdir -p "$B/root/Applications"
APP="$B/root/Applications/YiQi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13 -o "$APP/Contents/MacOS/YiQi" "$ROOT"/macos/Sources/*.swift
cp -R "$ROOT/build/rime-data" "$APP/Contents/Resources/rime-data"
VERSION=1.0.$(date +%Y%m%d%H%M)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>im.yiqi.app</string>
<key>CFBundleName</key><string>YiQi</string>
<key>CFBundleDisplayName</key><string>一炁输入法</string>
<key>CFBundleExecutable</key><string>YiQi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"

pkgbuild --quiet --root "$B/root" --install-location / --identifier im.yiqi.app --version "$VERSION" \
  --scripts "$ROOT/macos/pkg-scripts" "$B/yiqi.pkg"
mkdir -p "$ROOT/dist"
productbuild --quiet --package "$SQUIRREL_PKG" --package "$B/yiqi.pkg" "$ROOT/dist/YiQi-macOS.pkg"
echo "$ROOT/dist/YiQi-macOS.pkg"
