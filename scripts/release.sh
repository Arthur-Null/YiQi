#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="${1:?用法：先改 VERSION，再运行 scripts/release.sh <发布说明文件>}"
V=$(cat "$ROOT/VERSION")
"$ROOT/macos/build.sh"
"$ROOT/android/build.sh"
gh release create "v$V" --title "一炁输入法 v$V" --notes-file "$NOTES" \
  "$ROOT/dist/YiQi-macOS.pkg" "$ROOT/dist/YiQi-Android.apk"
