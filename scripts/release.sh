#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="${1:?用法：先改 VERSION，再运行 scripts/release.sh <发布说明文件> [--pre]（--pre 发布测试版）}"
PRE=()
[ "${2:-}" = "--pre" ] && PRE=(--prerelease)
V=$(cat "$ROOT/VERSION")
"$ROOT/android/build.sh"
if [ ${#PRE[@]} -gt 0 ]; then
  ASSETS=("$ROOT/dist/YiQi-Android.apk")
else
  "$ROOT/macos/build.sh"
  ASSETS=("$ROOT/dist/YiQi-macOS.pkg" "$ROOT/dist/YiQi-Android.apk")
  for extra in "$ROOT/dist/YiQi-Windows-Setup.exe" "$ROOT/dist/YiQi-Linux-x86_64.tar.gz" "$ROOT/dist/YiQi-Linux-amd64.deb" "$ROOT/dist/YiQi-iOS.ipa"; do
    [ -f "$extra" ] && ASSETS+=("$extra")
  done
fi
gh release create "v$V" ${PRE[@]+"${PRE[@]}"} --title "一炁输入法 v$V" --notes-file "$NOTES" "${ASSETS[@]}"
