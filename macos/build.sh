#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/macos"
VERSION=$(cat "$ROOT/VERSION")

rm -rf "$B/root" "$B/yiqi.pkg" && mkdir -p "$B/root/Applications" "$B/root/Library/Input Methods"
"$ROOT/macos/inputmethod/build.sh" >/dev/null
cp -R "$B/inputmethod/YiQiInput.app" "$B/root/Library/Input Methods/"

APP="$B/root/Applications/YiQi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13 -o "$APP/Contents/MacOS/YiQi" "$ROOT"/macos/Sources/*.swift
cp "$B/YiQi.icns" "$APP/Contents/Resources/YiQi.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>im.yiqi.app</string>
<key>CFBundleName</key><string>YiQi</string>
<key>CFBundleDisplayName</key><string>一炁输入法</string>
<key>CFBundleExecutable</key><string>YiQi</string>
<key>CFBundleIconFile</key><string>YiQi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"

# C1: 两个程序都必须装到固定位置，不能被安装程序「搬到」别处已有的同名副本上
pkgbuild --analyze --root "$B/root" "$B/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$B/components.plist"
plutil -replace 1.BundleIsRelocatable -bool NO "$B/components.plist"
pkgbuild --quiet --root "$B/root" --component-plist "$B/components.plist" --install-location / \
  --identifier im.yiqi.app --version "$VERSION" --scripts "$ROOT/macos/pkg-scripts" "$B/yiqi.pkg"
mkdir -p "$ROOT/dist"
productbuild --quiet --package "$B/yiqi.pkg" "$ROOT/dist/YiQi-macOS.pkg"
echo "$ROOT/dist/YiQi-macOS.pkg"
