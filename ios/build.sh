#!/bin/bash
# C1, C6: 构建 iOS 版「一炁输入法」（YiQi.app + YiQiKeyboard.appex），输出 dist/YiQi-iOS.ipa。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
B="$ROOT/build/ios"
VERSION="$(cat "$ROOT/VERSION")"
LIBRIME_PACK="1.17.0-pack.10.0.0"
FW_ZIP="$ROOT/build/dl/librime-static.xcframework.zip"

mkdir -p "$B" "$ROOT/build/dl" "$ROOT/dist" "$IOS/Resources/SharedSupport" "$IOS/Frameworks"

# 1. 下载预编译的 librime-static.xcframework（含 librime 1.17.0 + librime-lua + opencc）
if [ ! -d "$IOS/Frameworks/librime-static.xcframework" ]; then
  [ -f "$FW_ZIP" ] || curl -fL -o "$FW_ZIP" \
    "https://github.com/ghostflyby/librime-xcframework/releases/download/$LIBRIME_PACK/librime-static.xcframework.zip"
  unzip -q -o "$FW_ZIP" -d "$IOS/Frameworks"
fi

# 2. 准备雾凇词库、一炁补丁与预编译 .bin
"$ROOT/scripts/rime_data.sh" >/dev/null
rm -rf "$IOS/Resources/SharedSupport"
mkdir -p "$IOS/Resources/SharedSupport"
rsync -a --exclude 'squirrel.yaml' --exclude 'weasel.yaml' --exclude 'LICENSE' \
  "$ROOT/build/rime-data/" "$IOS/Resources/SharedSupport/"

if [ -d /opt/homebrew/opt/librime ]; then
  PRE="$B/prebuild"
  rm -rf "$PRE" && mkdir -p "$PRE"
  clang -O1 -I/opt/homebrew/opt/librime/include -L/opt/homebrew/opt/librime/lib -lrime \
    "$ROOT/tests/rime/harness.c" -o "$ROOT/build/rime_harness"
  echo | "$ROOT/build/rime_harness" "$ROOT/build/rime-data" "$PRE" "$PRE/build" deploy >/dev/null 2>&1 || true
  if [ -d "$PRE/build" ]; then
    mkdir -p "$IOS/Resources/SharedSupport/build"
    cp "$PRE"/build/* "$IOS/Resources/SharedSupport/build/" 2>/dev/null || true
  fi
fi

# 3. 同步版本号并生成 Xcode 工程
python3 - "$IOS/project.yml" "$VERSION" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
v = sys.argv[2]
code = "".join(f"{int(x):02d}" for x in v.split("."))
s = p.read_text()
s = re.sub(r'MARKETING_VERSION: "[^"]+"', f'MARKETING_VERSION: "{v}"', s)
s = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]+"', f'CURRENT_PROJECT_VERSION: "{code}"', s)
p.write_text(s)
PY

cd "$IOS"
xcodegen generate

# 4. 在 iOS 模拟器上运行单元测试（C2, C3, C5, C7）
xcodebuild test -project YiQi.xcodeproj -scheme YiQiTests \
  -destination 'platform=iOS Simulator,name=iPhone Air' CODE_SIGNING_ALLOWED=NO >/dev/null

# 5. 编译真机包并打包为 dist/YiQi-iOS.ipa（无签名，可通过 AltStore / SideStore / TrollStore / Xcode 安装）
xcodebuild -project YiQi.xcodeproj -scheme YiQi -configuration Release \
  -sdk iphoneos -derivedDataPath "$B/derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" QI_BUILD="$(date +%m%d-%H%M)" build

APP="$B/derived/Build/Products/Release-iphoneos/YiQi.app"
rm -rf "$B/Payload" "$ROOT/dist/YiQi-iOS.ipa"
mkdir -p "$B/Payload"
cp -R "$APP" "$B/Payload/"
(cd "$B" && zip -qr "$ROOT/dist/YiQi-iOS.ipa" Payload)
echo "$ROOT/dist/YiQi-iOS.ipa"
