#!/bin/bash
# C1, C6: 编译「一炁输入法」本体（基于鼠须管 1.1.2 源码），输出 build/macos/YiQiInput.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="$ROOT/build/macos/inputmethod"
SQUIRREL_TAG=1.1.2
LIBRIME_COMMIT=a251145d3aafa33871824a40bbec04c966bd8b56
SQUIRREL_PKG="$ROOT/build/dl/Squirrel-$SQUIRREL_TAG.pkg"
VERSION=$(cat "$ROOT/VERSION")

rm -rf "$B" && mkdir -p "$B"
git clone -q --depth 1 -b "$SQUIRREL_TAG" https://github.com/rime/squirrel.git "$B/src"
git init -q "$B/librime"
git -C "$B/librime" fetch -q --depth 1 https://github.com/rime/librime.git "$LIBRIME_COMMIT"
git -C "$B/librime" checkout -q FETCH_HEAD
python3 "$ROOT/macos/inputmethod/patch.py" "$B/src"

[ -f "$SQUIRREL_PKG" ] || { mkdir -p "$ROOT/build/dl"; curl -fL -o "$SQUIRREL_PKG" "https://github.com/rime/squirrel/releases/download/$SQUIRREL_TAG/Squirrel-$SQUIRREL_TAG.pkg"; }
pkgutil --expand "$SQUIRREL_PKG" "$B/pkg"
mkdir -p "$B/payload" && (cd "$B/payload" && gunzip -dc "$B/pkg/Payload" | cpio -i --quiet)
REL="$B/payload/Squirrel.app"

APP="$B/YiQiInput.app"
mkdir -p "$APP/Contents/MacOS"
cp -R "$REL/Contents/Resources" "$APP/Contents/"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$REL/Contents/Frameworks/librime.1.dylib" "$REL/Contents/Frameworks/rime-plugins" "$APP/Contents/Frameworks/"
cp "$REL/Contents/PkgInfo" "$APP/Contents/"

swiftc -O -target arm64-apple-macos13 -module-name Squirrel -enable-bare-slash-regex \
  -import-objc-header "$B/src/sources/Squirrel-Bridging-Header.h" -I "$B/librime/src" -I "$B/librime/include" \
  "$B/src/sources/"*.swift -o "$APP/Contents/MacOS/YiQiInput" \
  -Xlinker "$APP/Contents/Frameworks/librime.1.dylib" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework InputMethodKit -framework QuartzCore -framework UserNotifications -framework Carbon

# C1: 词库与一炁的配置放进输入法自带的数据目录，并预先编译词库，首次使用无需长时间部署
"$ROOT/scripts/rime_data.sh" >/dev/null
SHARED="$APP/Contents/SharedSupport"
mkdir -p "$SHARED"
for f in key_bindings.yaml punctuation.yaml symbols.yaml; do
  [ -f "$REL/Contents/SharedSupport/$f" ] && cp "$REL/Contents/SharedSupport/$f" "$SHARED/"
done
cp -R "$REL/Contents/SharedSupport/opencc" "$SHARED/"
rsync -a --exclude 'weasel.yaml' --exclude 'LICENSE' "$ROOT/build/rime-data/" "$SHARED/"
PRE="$B/prebuild"
mkdir -p "$PRE"
clang -O1 -I/opt/homebrew/opt/librime/include -L/opt/homebrew/opt/librime/lib -lrime \
  "$ROOT/tests/rime/harness.c" -o "$ROOT/build/rime_harness"
echo | "$ROOT/build/rime_harness" "$ROOT/build/rime-data" "$PRE" "$PRE/build" deploy >/dev/null 2>&1
mkdir -p "$SHARED/build"
cp "$PRE"/build/*.bin "$SHARED/build/"

S=/tmp/yiqi-icons-$$
mkdir -p "$S"
swiftc -O -o "$S/gen" "$ROOT/macos/inputmethod/icons.swift"
"$S/gen" "$S"
iconutil -c icns "$S/YiQi.iconset" -o "$APP/Contents/Resources/YiQi.icns"
cp "$S/yiqi.pdf" "$APP/Contents/Resources/yiqi.pdf"
cp "$APP/Contents/Resources/YiQi.icns" "$ROOT/build/macos/YiQi.icns"
rm -rf "$S"

python3 - "$REL/Contents/Info.plist" "$APP" "$VERSION" <<'PY'
import plistlib, sys, copy, pathlib
src, app, version = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
p = plistlib.load(open(src, "rb"))
for k in [k for k in p if k.startswith("SU") or k.startswith("DT") or k == "BuildMachineOSBuild" or k == "CFBundleIconName"]:
    del p[k]
p.update({
    "CFBundleExecutable": "YiQiInput", "CFBundleIdentifier": "im.yiqi.inputmethod", "CFBundleName": "YiQiInput",
    "CFBundleDisplayName": "一炁输入法", "CFBundleVersion": version, "CFBundleShortVersionString": version,
    "CFBundleIconFile": "YiQi", "InputMethodConnectionName": "YiQiInput_Connection",
    "tsInputMethodIconFileKey": "yiqi.pdf", "TISInputSourceID": "im.yiqi.inputmethod",
})
modes = p["ComponentInputModeDict"]
hans = copy.deepcopy(modes["tsInputModeListKey"]["im.rime.inputmethod.Squirrel.Hans"])
hans["TISInputSourceID"] = "im.yiqi.inputmethod.pinyin"
for k in ["tsInputModeAlternateMenuIconFileKey", "tsInputModeMenuIconFileKey", "tsInputModePaletteIconFileKey"]:
    hans[k] = "yiqi.pdf"
hans["TISIconIsTemplate"] = True
modes["tsInputModeListKey"] = {"im.yiqi.inputmethod.pinyin": hans}
modes["tsVisibleInputModeOrderedArrayKey"] = ["im.yiqi.inputmethod.pinyin"]
plistlib.dump(p, open(app / "Contents/Info.plist", "wb"))
for lang, name in [("en", "YiQi"), ("zh-Hans", "一炁输入法"), ("zh-Hant", "一炁輸入法")]:
    d = app / f"Contents/Resources/{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    plistlib.dump({"CFBundleDisplayName": name, "CFBundleName": name, "im.yiqi.inputmethod": name,
                   "im.yiqi.inputmethod.pinyin": name}, open(d / "InfoPlist.strings", "wb"))
PY
rm -f "$APP/Contents/Resources/rime.pdf" "$APP/Contents/Resources/Rime.icns"
codesign --force --deep -s - "$APP"
echo "$APP"
