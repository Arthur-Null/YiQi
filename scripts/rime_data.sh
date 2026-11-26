#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIME_FROST_COMMIT=caa8ac9d013307670f81b71b42b53b0296d3af05
SRC="$ROOT/build/src/rime-frost"
OUT="$ROOT/build/rime-data"

if [ ! -d "$SRC/.git" ]; then
  git clone -q https://github.com/gaboolic/rime-frost.git "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$RIME_FROST_COMMIT" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$RIME_FROST_COMMIT"
  git -C "$SRC" checkout -q "$RIME_FROST_COMMIT"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude .git --exclude .github --exclude others --exclude README.md --exclude AGENTS.md \
  --exclude 'bopomofo*' --exclude 'cangjie5*' --exclude 'stroke.*' --exclude 'luna_pinyin.dict.yaml' \
  --exclude 'rime_frost_14key.schema.yaml' --exclude 'rime_frost_t9.schema.yaml' --exclude 'rime_frost_stroke_t9.schema.yaml' \
  --exclude 'rime_frost_double_pinyin.schema.yaml' --exclude 'rime_frost_double_pinyin_14key.schema.yaml' \
  --exclude 'rime_frost_double_pinyin_abc.schema.yaml' --exclude 'rime_frost_double_pinyin_flypy_14key.schema.yaml' \
  --exclude 'rime_frost_double_pinyin_mspy.schema.yaml' --exclude 'rime_frost_double_pinyin_sogou.schema.yaml' \
  --exclude 'rime_frost_double_pinyin_ziguang.schema.yaml' --exclude 'rime_frost_moqi_single_xh*' \
  --exclude 'rime_frost_wubi86*' --exclude 'cn_dicts_wb' --exclude 'melt_eng_t9.schema.yaml' --exclude 'build' \
  "$SRC/" "$OUT/"
rsync -a "$ROOT/rime/" "$OUT/"
for f in default:default rime_frost.schema:rime_frost rime_frost_double_pinyin_flypy.schema:rime_frost_double_pinyin_flypy squirrel:squirrel weasel:weasel; do
  printf '\n__patch:\n  - qi_patch:/%s\n  - %s.custom:/patch?\n' "${f#*:}" "${f#*:}" >> "$OUT/${f%%:*}.yaml"
done
(cd "$OUT" && find . -type f ! -name qi_data_version.txt | LC_ALL=C sort | xargs shasum | shasum | cut -c1-16) > "$OUT/qi_data_version.txt"
echo "$OUT"
