#!/bin/bash
# C1, C6: 构建 Linux 版「一炁输入法」（tar.gz 通用安装包 + Debian/Ubuntu .deb 安装包）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64) GO_ARCH=amd64; TAR_ARCH=x86_64; DEB_ARCH=amd64 ;;
  aarch64|arm64) GO_ARCH=arm64; TAR_ARCH=arm64; DEB_ARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

B="$ROOT/build/linux/$TAR_ARCH"
STAGE="$B/stage"
rm -rf "$B" && mkdir -p "$STAGE/bin" "$STAGE/icons" "$STAGE/themes" "$STAGE/rime-data" "$ROOT/dist"

# 1. 准备雾凇拼音与一炁补丁
"$ROOT/scripts/rime_data.sh" >/dev/null
rsync -a --exclude 'squirrel.yaml' --exclude 'weasel.yaml' --exclude 'LICENSE' \
  "$ROOT/build/rime-data/" "$STAGE/rime-data/"

# 若本机有 librime 头文件与库，预编译词库 .bin，首次启动立即可用
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists rime; then
  PRE="$B/prebuild"
  mkdir -p "$PRE"
  cc -O1 $(pkg-config --cflags rime) "$ROOT/tests/rime/harness.c" $(pkg-config --libs rime) -o "$B/rime_harness"
  echo | "$B/rime_harness" "$ROOT/build/rime-data" "$PRE" "$PRE/build" deploy >/dev/null 2>&1 || true
  if [ -d "$PRE/build" ]; then
    mkdir -p "$STAGE/rime-data/build"
    cp "$PRE"/build/* "$STAGE/rime-data/build/" 2>/dev/null || true
  fi
fi

# 2. 编译 Go 守护进程（yiqi）
(
  cd "$ROOT/linux/app"
  GOOS=linux GOARCH="$GO_ARCH" CGO_ENABLED=0 \
    go build -ldflags "-s -w -X main.version=$VERSION" -o "$STAGE/bin/yiqi" .
)

# 3. 在 Linux 上编译原生 GTK3 设置窗口与托盘程序（yiqi-ui）
if [ "$(uname -s)" = "Linux" ] && command -v pkg-config >/dev/null 2>&1 && pkg-config --exists gtk+-3.0; then
  cc -O2 -Wall -Wextra $(pkg-config --cflags gtk+-3.0) "$ROOT/linux/ui/yiqi-ui.c" $(pkg-config --libs gtk+-3.0) -o "$STAGE/bin/yiqi-ui"
fi

cp "$ROOT/linux/icons/yiqi.svg" "$STAGE/icons/"
rsync -a "$ROOT/linux/themes/" "$STAGE/themes/"
cp "$ROOT/linux/yiqi.desktop" "$ROOT/linux/yiqi-autostart.desktop" "$ROOT/linux/install.sh" "$STAGE/"
chmod +x "$STAGE/install.sh"

# 4. 打包通用 .tar.gz
TAR_OUT="$ROOT/dist/YiQi-Linux-$TAR_ARCH.tar.gz"
tar -czf "$TAR_OUT" -C "$STAGE" .
echo "$TAR_OUT"

# 5. 若有 dpkg-deb，同时打包 .deb 安装包（Ubuntu / Debian 双击即装）
if command -v dpkg-deb >/dev/null 2>&1 && [ -f "$STAGE/bin/yiqi-ui" ]; then
  DEB="$B/deb"
  mkdir -p "$DEB/DEBIAN" "$DEB/usr/bin" "$DEB/usr/share/yiqi" \
    "$DEB/usr/share/icons/hicolor/scalable/apps" \
    "$DEB/usr/share/applications" "$DEB/etc/xdg/autostart" \
    "$DEB/usr/share/fcitx5/themes"
  install -m 755 "$STAGE/bin/yiqi" "$DEB/usr/bin/yiqi"
  install -m 755 "$STAGE/bin/yiqi-ui" "$DEB/usr/bin/yiqi-ui"
  install -m 644 "$STAGE/icons/yiqi.svg" "$DEB/usr/share/icons/hicolor/scalable/apps/yiqi.svg"
  install -m 644 "$ROOT/linux/yiqi.desktop" "$DEB/usr/share/applications/yiqi.desktop"
  install -m 644 "$ROOT/linux/yiqi-autostart.desktop" "$DEB/etc/xdg/autostart/yiqi.desktop"
  rsync -a "$STAGE/rime-data/" "$DEB/usr/share/yiqi/rime-data/"
  rsync -a "$STAGE/themes/" "$DEB/usr/share/fcitx5/themes/"
  cat > "$DEB/DEBIAN/control" <<CTL
Package: yiqi-input
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Depends: libgtk-3-0, fcitx5-rime | ibus-rime
Recommends: librime-plugin-lua, wl-clipboard | xclip
Maintainer: YiQi <yiqi@example.com>
Description: 一炁输入法（小鹤双拼 / 全拼 + 跨设备剪贴板同步）
CTL
  cat > "$DEB/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ -n "${SUDO_USER:-}" ]; then
  UHOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  if [ -n "$UHOME" ]; then
    su - "$SUDO_USER" -c "mkdir -p '$UHOME/.local/share/fcitx5/rime' && cp -rn /usr/share/yiqi/rime-data/* '$UHOME/.local/share/fcitx5/rime/'" || true
  fi
fi
gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
POST
  chmod 755 "$DEB/DEBIAN/postinst"
  DEB_OUT="$ROOT/dist/YiQi-Linux-$DEB_ARCH.deb"
  dpkg-deb --build --root-owner-group "$DEB" "$DEB_OUT" >/dev/null
  echo "$DEB_OUT"
fi
