#!/bin/bash
# C4, C7: 把剪贴板中转部署到任意一台可 ssh 登录的 Linux 服务器。
# 用法：server/deploy.sh <ssh 主机> <公网地址，如 wss://yiqi.example.com/v1/ws> <本机端口>
# 中转只监听服务器的 127.0.0.1:<端口>，由部署者自己的隧道或反向代理把公网地址转到这个端口。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$1"
URL="$2"
PORT="$3"

ARCH=$(ssh "$HOST" uname -m)
case "$ARCH" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) echo "unsupported $ARCH"; exit 1 ;; esac
(cd "$ROOT/sync" && GOOS=linux GOARCH=$GOARCH CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$ROOT/build/server/yiqi-relay" ./cmd/yiqi-relay)
scp -q "$ROOT/build/server/yiqi-relay" "$HOST:/usr/local/bin/yiqi-relay.new"
sed "s/PORT/$PORT/" "$ROOT/server/yiqi-relay.service" | ssh "$HOST" "cat > /etc/systemd/system/yiqi-relay.service"
ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
mv /usr/local/bin/yiqi-relay.new /usr/local/bin/yiqi-relay
chmod 755 /usr/local/bin/yiqi-relay
id yiqi-relay >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin yiqi-relay
install -d -o yiqi-relay -m 700 /var/lib/yiqi-relay
systemctl daemon-reload
systemctl enable -q yiqi-relay
REMOTE

# C5: 首次部署生成配对码，只保存在运行本脚本的这台 Mac 的一炁里，由它向自己的其他设备展示
PAIR="$HOME/Library/Application Support/YiQi/pair.txt"
if ! ssh "$HOST" test -f /var/lib/yiqi-relay/verifier; then
  mkdir -p "$(dirname "$PAIR")"
  CODE=$(ssh "$HOST" "runuser -u yiqi-relay -- /usr/local/bin/yiqi-relay init --data /var/lib/yiqi-relay --url $URL")
  (umask 077; printf '%s' "$CODE" > "$PAIR")
  echo "配对码已保存到 $PAIR"
fi
ssh "$HOST" "systemctl restart yiqi-relay && sleep 1 && systemctl is-active yiqi-relay"
