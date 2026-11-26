#!/bin/bash
# C4, C7: 把剪贴板中转部署到任意一台可 ssh 登录的 Linux 服务器。
# 用法：server/deploy.sh <ssh 主机> <本机端口>
# 中转只监听服务器的 127.0.0.1:<端口>，由部署者自己的隧道或反向代理把域名转到这个端口；
# 注册新同步组用的临时密码：在服务器上运行 yiqi-relay code [--name 组名] 生成（10 分钟内有效）；一台服务器可有多个同步组，
# yiqi-relay list 查看。某组的设备都丢失时，运行 yiqi-relay reset <组名或编号> 删除该组（其他组不受影响），再生成临时密码重新注册。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$1"
PORT="$2"

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

ssh "$HOST" "systemctl restart yiqi-relay && sleep 1 && systemctl is-active yiqi-relay"
# C5, C8: 生成注册新同步组用的临时密码（10 分钟内有效；过期后在服务器上运行 yiqi-relay code 再生成）
ssh "$HOST" "/usr/local/bin/yiqi-relay code --data /var/lib/yiqi-relay" || true
