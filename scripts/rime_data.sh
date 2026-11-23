#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIME_ICE_COMMIT=927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6
SRC="$ROOT/build/src/rime-ice"
OUT="$ROOT/build/rime-data"

if [ ! -d "$SRC/.git" ]; then
  git clone -q https://github.com/iDvel/rime-ice.git "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$RIME_ICE_COMMIT" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$RIME_ICE_COMMIT"
  git -C "$SRC" checkout -q "$RIME_ICE_COMMIT"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude .git --exclude .github --exclude others --exclude README.md --exclude AGENTS.md \
  --exclude 'double_pinyin.schema.yaml' --exclude 'double_pinyin_abc.schema.yaml' \
  --exclude 'double_pinyin_jiajia.schema.yaml' --exclude 'double_pinyin_mspy.schema.yaml' \
  --exclude 'double_pinyin_sogou.schema.yaml' --exclude 'double_pinyin_ziguang.schema.yaml' \
  --exclude 't9.schema.yaml' --exclude 'build' \
  "$SRC/" "$OUT/"
rsync -a "$ROOT/rime/" "$OUT/"
for f in default:default rime_ice.schema:rime_ice double_pinyin_flypy.schema:double_pinyin_flypy; do
  printf '\n__patch:\n  - qi_patch:/%s\n  - %s.custom:/patch?\n' "${f#*:}" "${f#*:}" >> "$OUT/${f%%:*}.yaml"
done
(cd "$OUT" && find . -type f ! -name qi_data_version.txt | LC_ALL=C sort | xargs shasum | shasum | cut -c1-16) > "$OUT/qi_data_version.txt"
echo "$OUT"
