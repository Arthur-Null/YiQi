#!/bin/bash
# C1, C2, C6: 安装或升级 Linux 版「一炁输入法」（支持 Fcitx5 与 IBus，升级保留用户 *.custom.yaml 与同步凭据）。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
UPGRADE=0
for arg in "$@"; do
  [ "$arg" = "--upgrade" ] && UPGRADE=1
done

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yiqi"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTO_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

mkdir -p "$BIN_DIR" "$DATA_DIR/rime-data" "$ICON_DIR" "$APP_DIR" "$AUTO_DIR"

# 升级前平滑结束旧进程
if [ -S "${XDG_RUNTIME_DIR:-/tmp}/yiqi.sock" ]; then
  "$BIN_DIR/yiqi" --status >/dev/null 2>&1 || true
fi
pkill -x yiqi-ui >/dev/null 2>&1 || true
pkill -x yiqi >/dev/null 2>&1 || true
sleep 0.3

install -m 755 "$SRC/bin/yiqi" "$BIN_DIR/yiqi"
if [ -f "$SRC/bin/yiqi-ui" ]; then
  install -m 755 "$SRC/bin/yiqi-ui" "$BIN_DIR/yiqi-ui"
fi
install -m 644 "$SRC/icons/yiqi.svg" "$ICON_DIR/yiqi.svg"
sed "s|^Exec=yiqi|Exec=$BIN_DIR/yiqi|" "$SRC/yiqi.desktop" > "$APP_DIR/yiqi.desktop"
sed "s|^Exec=yiqi|Exec=$BIN_DIR/yiqi|" "$SRC/yiqi-autostart.desktop" > "$AUTO_DIR/yiqi.desktop"

# 安装雾凇词库与一炁补丁（保留用户 *.custom.yaml 与用户词典）
rsync -a --exclude '*.custom.yaml' --exclude 'user.yaml' --exclude 'installation.yaml' \
  --exclude 'qi_schema.txt' --exclude 'qi_hotkey.txt' --exclude '*.userdb' \
  "$SRC/rime-data/" "$DATA_DIR/rime-data/"

install_rime_dir() {
  local dst="$1"
  mkdir -p "$dst"
  rsync -a --exclude '*.custom.yaml' --exclude 'user.yaml' --exclude 'installation.yaml' \
    --exclude 'qi_schema.txt' --exclude 'qi_hotkey.txt' --exclude '*.userdb' \
    "$SRC/rime-data/" "$dst/"
}

INSTALLED_FW=""
if command -v fcitx5 >/dev/null 2>&1 || [ -d "$HOME/.local/share/fcitx5" ]; then
  install_rime_dir "$HOME/.local/share/fcitx5/rime"
  mkdir -p "$HOME/.local/share/fcitx5/themes"
  rsync -a "$SRC/themes/yiqi-light" "$SRC/themes/yiqi-dark" "$HOME/.local/share/fcitx5/themes/"
  CLASSICUI="$HOME/.config/fcitx5/conf/classicui.conf"
  if [ ! -f "$CLASSICUI" ] || [ "$UPGRADE" -eq 0 ]; then
    mkdir -p "$(dirname "$CLASSICUI")"
    cat > "$CLASSICUI" <<'CONF'
Vertical Candidate List=False
UsePerScreenDPI=True
Theme=yiqi-light
DarkTheme=yiqi-dark
UseDarkTheme=True
CONF
  fi
  INSTALLED_FW="fcitx5"
fi

if command -v ibus >/dev/null 2>&1 || [ -d "$HOME/.config/ibus/rime" ]; then
  install_rime_dir "$HOME/.config/ibus/rime"
  [ -z "$INSTALLED_FW" ] && INSTALLED_FW="ibus"
fi

if [ -z "$INSTALLED_FW" ]; then
  install_rime_dir "$HOME/.local/share/fcitx5/rime"
fi

command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -f "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APP_DIR" >/dev/null 2>&1 || true

if [ "$INSTALLED_FW" = "fcitx5" ] && command -v fcitx5-remote >/dev/null 2>&1; then
  fcitx5-remote -r >/dev/null 2>&1 || true
elif [ "$INSTALLED_FW" = "ibus" ] && command -v ibus >/dev/null 2>&1; then
  ibus engine rime >/dev/null 2>&1 || true
fi

if [ "$UPGRADE" -eq 1 ]; then
  nohup "$BIN_DIR/yiqi" --background >/dev/null 2>&1 &
else
  nohup "$BIN_DIR/yiqi" --settings >/dev/null 2>&1 &
fi

echo "一炁输入法安装完成。"
