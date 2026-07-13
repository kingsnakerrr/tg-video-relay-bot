#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${1:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
DOMAIN="${2:-${DOMAIN:-}}"
INSTALL_DIR="${DRIVEPIC_DIR:-/opt/drivepic}"

if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null; then
    echo "当前不是 root 用户，且系统没有 sudo。请切换 root 后重试。"
    exit 1
  fi
  TEMP_INSTALLER="$(mktemp)"
  cp "$0" "$TEMP_INSTALLER"
  chmod 700 "$TEMP_INSTALLER"
  exec sudo -E bash "$TEMP_INSTALLER" "$@"
fi
case "$INSTALL_DIR" in
  /opt/*) ;;
  *) echo "安装目录必须位于 /opt 下。"; exit 1 ;;
esac
if [ -z "$DOMAIN" ]; then
  echo "请输入已经解析到本 VPS 的图床域名。"
  read -rp "图床域名（例如 img.example.com）: " DOMAIN
fi
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "域名格式不正确。"
  exit 1
fi

if ! command -v curl >/dev/null || ! command -v git >/dev/null; then
  apt-get update
  apt-get install -y curl git ca-certificates
fi
if ! command -v docker >/dev/null; then
  echo "正在安装 Docker…"
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "当前 Docker 缺少 Compose 插件，请先安装 docker-compose-plugin。"
  exit 1
fi

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "检测到已有安装，正在更新代码…"
  git -C "$INSTALL_DIR" pull --ff-only
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
mkdir -p data
chmod 700 data
chown 1000:1000 data
cat > .env <<EOF
PORT=3000
MAX_UPLOAD_MB=25
TRUST_PROXY=true
TZ=Asia/Shanghai
DOMAIN=$DOMAIN
EOF

docker compose up -d --build
ln -sf "$INSTALL_DIR/scripts/drivepic" /usr/local/bin/drivepic
chmod +x "$INSTALL_DIR/scripts/drivepic"

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 7077/tcp >/dev/null
  ufw allow 7078/tcp >/dev/null
fi

for _ in $(seq 1 30); do
  [ -f "$INSTALL_DIR/data/.admin-password" ] && break
  sleep 1
done
ADMIN_PASSWORD="$(cat "$INSTALL_DIR/data/.admin-password" 2>/dev/null || echo '运行 drivepic credentials 查看')"

echo
echo "=============================================="
echo "  砰！图床安装完成"
echo "  前端地址：https://$DOMAIN:7078/"
echo "  后端地址：https://$DOMAIN:7077/admin"
echo "  后台账号：admin"
echo "  后台随机密码：$ADMIN_PASSWORD"
echo "=============================================="
echo "若打不开，请确认域名已解析到本机，且防火墙/安全组开放 80、443、7077、7078 端口。"
echo "请先登录后台配置 Google 团队盘，再创建前端登录账号。"
echo "管理命令：drivepic status | logs | update | restart | credentials"
