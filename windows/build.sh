#!/bin/bash
# C1, C6: 在 Linux / Docker 环境下交叉构建完整的 Windows 安装程序（dist/YiQi-Windows-Setup.exe）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
B="$ROOT/build/windows"
STAGE="$B/stage"
WEASEL_TAG="0.17.4"
WEASEL_EXE="$ROOT/build/dl/weasel-0.17.4.0-installer.exe"

rm -rf "$STAGE" && mkdir -p "$STAGE/data" "$ROOT/build/dl" "$ROOT/dist"

# 1. 准备雾凇词库与一炁补丁（含 weasel.yaml）
"$ROOT/scripts/rime_data.sh" >/dev/null
rsync -a --exclude 'squirrel.yaml' --exclude 'LICENSE' "$ROOT/build/rime-data/" "$STAGE/data/"

# 若有 librime，预编译词库 .bin
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists rime; then
  PRE="$B/prebuild"
  rm -rf "$PRE" && mkdir -p "$PRE"
  cc -O1 $(pkg-config --cflags rime) "$ROOT/tests/rime/harness.c" $(pkg-config --libs rime) -o "$B/rime_harness"
  echo | "$B/rime_harness" "$ROOT/build/rime-data" "$PRE" "$PRE/build" deploy >/dev/null 2>&1 || true
  if [ -d "$PRE/build" ]; then
    mkdir -p "$STAGE/data/build"
    cp "$PRE"/build/* "$STAGE/data/build/" 2>/dev/null || true
  fi
fi

# 2. 提取官方小狼毫 0.17.4 运行时（含 rime.dll 与 librime-lua）
if [ ! -f "$WEASEL_EXE" ]; then
  curl -fL -o "$WEASEL_EXE" \
    "https://github.com/rime/weasel/releases/download/$WEASEL_TAG/weasel-0.17.4.0-installer.exe"
fi
EX="$B/weasel-bin"
rm -rf "$EX" && mkdir -p "$EX"
7z x -aou "-o$EX" "$WEASEL_EXE" >/dev/null

# C1: 保留 x64 服务端/引擎与 32/64 位 TSF DLL，避免同名 x86 覆盖 x64
for f in WeaselServer.exe WeaselDeployer.exe WeaselSetup.exe rime.dll WinSparkle.dll weasel.dll weaselx64.dll weasel.ime weaselx64.ime; do
  [ -f "$EX/$f" ] && cp "$EX/$f" "$STAGE/$f"
done
SHARED_SRC="$(find "$EX" -type d -name data | head -n 1 || true)"
if [ -n "$SHARED_SRC" ]; then
  for f in key_bindings.yaml punctuation.yaml symbols.yaml; do
    [ -f "$SHARED_SRC/$f" ] && cp "$SHARED_SRC/$f" "$STAGE/data/$f"
  done
  [ -d "$SHARED_SRC/opencc" ] && cp -R "$SHARED_SRC/opencc" "$STAGE/data/"
fi

# 3. 交叉编译 Windows YiQi.exe
(
  cd "$ROOT/windows/app"
  GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
    go build -ldflags "-H=windowsgui -s -w -X main.version=$VERSION" -o "$STAGE/YiQi.exe" .
)

# 4. 使用 NSIS 打包安装程序
makensis -V2 "$ROOT/windows/installer/yiqi.nsi"
echo "$ROOT/dist/YiQi-Windows-Setup.exe"
