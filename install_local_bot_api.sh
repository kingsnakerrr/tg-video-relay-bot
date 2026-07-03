#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
LOCAL_API_NAME="${LOCAL_API_NAME:-telegram-bot-api}"
LOCAL_API_REPO="${LOCAL_API_REPO:-https://github.com/tdlib/telegram-bot-api.git}"
LOCAL_API_SRC="${LOCAL_API_SRC:-/opt/telegram-bot-api}"
LOCAL_API_BUILD="${LOCAL_API_BUILD:-/opt/telegram-bot-api/build}"
LOCAL_API_ENV="${LOCAL_API_ENV:-/etc/telegram-bot-api.env}"
LOCAL_API_SERVICE="/etc/systemd/system/${LOCAL_API_NAME}.service"
LOCAL_API_HOST="${LOCAL_API_HOST:-127.0.0.1}"
LOCAL_API_PORT="${LOCAL_API_PORT:-8081}"
BUILD_JOBS="${BUILD_JOBS:-1}"
INSTALL_LOG="${INSTALL_LOG:-/var/log/tg-video-relay-local-api-install.log}"
SWAP_FILE="${SWAP_FILE:-/swapfile-tg-video-relay}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root. / 请用 root 运行。"
    exit 1
  fi
}

step() {
  echo
  echo "==> $*"
}

env_value() {
  key="$1"
  file="${2:-${APP_DIR}/.env}"
  [ -f "${file}" ] || return
  grep -E "^${key}=" "${file}" | tail -n 1 | cut -d= -f2-
}

set_env_value() {
  file="$1"
  key="$2"
  value="$3"
  touch "${file}"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

write_local_env() {
  current_id="$(env_value TELEGRAM_API_ID "${LOCAL_API_ENV}" || true)"
  current_hash="$(env_value TELEGRAM_API_HASH "${LOCAL_API_ENV}" || true)"

  echo "Enter Telegram API credentials from https://my.telegram.org/apps"
  echo "请输入从 https://my.telegram.org/apps 申请到的 Telegram API 参数。"
  if [ -n "${current_id}" ]; then
    read -r -p "API ID / API ID 数字 [keep current / 回车保留当前 ${current_id}]: " api_id
    api_id="${api_id:-${current_id}}"
  else
    read -r -p "API ID / API ID 数字: " api_id
  fi

  if [ -n "${current_hash}" ]; then
    read -r -s -p "API hash / API hash 密钥 [press Enter to keep current / 回车保留当前]: " api_hash
    echo
    api_hash="${api_hash:-${current_hash}}"
  else
    read -r -s -p "API hash / API hash 密钥: " api_hash
    echo
  fi

  [ -n "${api_id}" ] || { echo "API ID is required. / 必须填写 API ID。"; exit 1; }
  [ -n "${api_hash}" ] || { echo "API hash is required. / 必须填写 API hash。"; exit 1; }

  cat > "${LOCAL_API_ENV}" <<EOF_ENV
TELEGRAM_API_ID=${api_id}
TELEGRAM_API_HASH=${api_hash}
EOF_ENV
  chmod 600 "${LOCAL_API_ENV}"
}

install_packages() {
  step "Installing build packages / 安装编译依赖"
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y git curl ca-certificates build-essential cmake gperf zlib1g-dev libssl-dev libreadline-dev
  else
    echo "This installer currently supports Debian/Ubuntu with apt."
    echo "当前脚本只支持 Debian/Ubuntu apt 系统。"
    exit 1
  fi
}

ensure_swap() {
  step "Ensuring swap for low-memory VPS / 为小内存 VPS 准备 swap"
  if swapon --noheadings --show=NAME 2>/dev/null | grep -qx "${SWAP_FILE}"; then
    echo "Swap already active / swap 已启用: ${SWAP_FILE}"
    return
  fi

  if [ ! -f "${SWAP_FILE}" ]; then
    echo "Creating ${SWAP_SIZE} swap file / 正在创建 ${SWAP_SIZE} swap 文件: ${SWAP_FILE}"
    fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}" 2>/dev/null || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=4096 status=progress
  fi

  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}" >/dev/null 2>&1 || true
  swapon "${SWAP_FILE}" 2>/dev/null || true

  if ! swapon --noheadings --show=NAME 2>/dev/null | grep -qx "${SWAP_FILE}"; then
    echo "WARNING: Could not enable swap. Build may fail on low-memory VPS."
    echo "警告: 无法启用 swap，小内存 VPS 编译可能失败。"
    return
  fi

  if ! grep -q "^${SWAP_FILE} " /etc/fstab 2>/dev/null; then
    printf '%s none swap sw 0 0\n' "${SWAP_FILE}" >> /etc/fstab
  fi
  free -h || true
}

build_local_api() {
  step "Downloading Telegram Local Bot API Server / 下载 Telegram 本地 Bot API 服务"
  if [ -d "${LOCAL_API_SRC}/.git" ]; then
    git -C "${LOCAL_API_SRC}" fetch origin
    git -C "${LOCAL_API_SRC}" pull --ff-only
    git -C "${LOCAL_API_SRC}" submodule update --init --recursive
  else
    mkdir -p "$(dirname "${LOCAL_API_SRC}")"
    git clone --recursive "${LOCAL_API_REPO}" "${LOCAL_API_SRC}"
  fi

  step "Building telegram-bot-api / 编译 telegram-bot-api"
  echo "Build jobs / 编译线程: ${BUILD_JOBS}"
  mkdir -p "${LOCAL_API_BUILD}"
  cmake -S "${LOCAL_API_SRC}" -B "${LOCAL_API_BUILD}" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
  cmake --build "${LOCAL_API_BUILD}" --target install -j"${BUILD_JOBS}"
}

write_service() {
  step "Writing systemd service / 写入 systemd 服务"
  mkdir -p /var/lib/telegram-bot-api /var/tmp/telegram-bot-api
  cat > "${LOCAL_API_SERVICE}" <<EOF_SERVICE
[Unit]
Description=Local Telegram Bot API Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${LOCAL_API_ENV}
ExecStart=/usr/local/bin/telegram-bot-api --api-id=\${TELEGRAM_API_ID} --api-hash=\${TELEGRAM_API_HASH} --local --http-ip-address=${LOCAL_API_HOST} --http-port=${LOCAL_API_PORT} --dir=/var/lib/telegram-bot-api --temp-dir=/var/tmp/telegram-bot-api
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

start_local_api() {
  step "Starting local Bot API service / 启动本地 Bot API 服务"
  systemctl daemon-reload
  systemctl enable --now "${LOCAL_API_NAME}"
  systemctl status "${LOCAL_API_NAME}" --no-pager -n 10 || true
}

bot_token() {
  env_value BOT_TOKEN "${APP_DIR}/.env"
}

check_local_api() {
  token="$(bot_token)"
  if [ -z "${token}" ]; then
    echo "BOT_TOKEN not found in ${APP_DIR}/.env / ${APP_DIR}/.env 中找不到 BOT_TOKEN"
    return 1
  fi
  curl -fsS "http://${LOCAL_API_HOST}:${LOCAL_API_PORT}/bot${token}/getMe"
}

switch_to_local_api() {
  step "Switching relay bot to local Bot API / 切换转发机器人到本地 Bot API"
  [ -f "${APP_DIR}/.env" ] || { echo "${APP_DIR}/.env not found. / 找不到 ${APP_DIR}/.env"; exit 1; }
  token="$(bot_token)"
  [ -n "${token}" ] || { echo "BOT_TOKEN not found in ${APP_DIR}/.env / ${APP_DIR}/.env 中找不到 BOT_TOKEN"; exit 1; }

  systemctl stop "${APP_NAME}" 2>/dev/null || true
  echo "Logging out from public Telegram Bot API. This is expected before local mode."
  echo "正在从公网 Telegram Bot API 登出，这是切换本地模式前的正常步骤。"
  curl -fsS "https://api.telegram.org/bot${token}/logOut" || true
  echo

  echo "Testing local Bot API... / 测试本地 Bot API..."
  check_local_api
  echo

  set_env_value "${APP_DIR}/.env" BOT_API_BASE_URL "http://${LOCAL_API_HOST}:${LOCAL_API_PORT}"
  set_env_value "${APP_DIR}/.env" BOT_API_USE_LOCAL_FILE_URI "true"
  set_env_value "${APP_DIR}/.env" MAX_UPLOAD_MB "1900"
  set_env_value "${APP_DIR}/.env" AUTO_COMPRESS "false"

  systemctl restart "${APP_NAME}"
  systemctl status "${APP_NAME}" --no-pager -n 10 || true
}

switch_to_public_api() {
  step "Switching relay bot back to public Telegram Bot API / 切回公网 Telegram Bot API"
  [ -f "${APP_DIR}/.env" ] || { echo "${APP_DIR}/.env not found. / 找不到 ${APP_DIR}/.env"; exit 1; }
  set_env_value "${APP_DIR}/.env" BOT_API_BASE_URL "https://api.telegram.org"
  set_env_value "${APP_DIR}/.env" BOT_API_USE_LOCAL_FILE_URI "false"
  set_env_value "${APP_DIR}/.env" MAX_UPLOAD_MB "49"
  set_env_value "${APP_DIR}/.env" AUTO_COMPRESS "true"
  systemctl restart "${APP_NAME}"
  systemctl status "${APP_NAME}" --no-pager -n 10 || true
}

status() {
  echo "== Local Bot API service / 本地 Bot API 服务 =="
  systemctl is-active "${LOCAL_API_NAME}" || true
  systemctl status "${LOCAL_API_NAME}" --no-pager -n 8 || true
  echo
  echo "== Listening port / 监听端口 =="
  ss -lntp 2>/dev/null | grep ":${LOCAL_API_PORT} " || echo "Not listening on ${LOCAL_API_PORT} / 未监听 ${LOCAL_API_PORT}"
  echo
  echo "== Relay upload settings / 转发机器人上传配置 =="
  printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL "${APP_DIR}/.env")"
  printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI "${APP_DIR}/.env")"
  printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB "${APP_DIR}/.env")"
  printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS "${APP_DIR}/.env")"
  echo
  echo "== Local getMe test / 本地 getMe 测试 =="
  check_local_api || true
  echo
}

menu() {
  cat <<EOF
Local Telegram Bot API Server / Telegram 本地 Bot API 服务

1) Install / update local Bot API server / 安装或更新本地 Bot API 服务
2) Continue install in background / 后台继续安装
3) Show background install log / 查看后台安装日志
4) Switch relay bot to local original-quality mode / 切换机器人到本地原画质模式
5) Show status / 查看状态
6) Logs / 日志
7) Switch relay bot back to public API / 切回公网 API
0) Exit / 退出
EOF
  echo
  read -r -p "Choose / 请选择: " choice
  case "${choice}" in
    1) install_all ;;
    2) install_background ;;
    3) tail -f "${INSTALL_LOG}" ;;
    4) switch_to_local_api ;;
    5) status ;;
    6) journalctl -u "${LOCAL_API_NAME}" -f ;;
    7) switch_to_public_api ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice. / 选择无效。"; exit 1 ;;
  esac
}

install_all() {
  install_packages
  ensure_swap
  write_local_env
  build_local_api
  write_service
  start_local_api
  echo
  echo "Local Bot API server is installed. / 本地 Bot API 服务已安装。"
  echo "Next step / 下一步: x local-api-switch"
}

install_without_prompt() {
  [ -f "${LOCAL_API_ENV}" ] || {
    echo "${LOCAL_API_ENV} not found. Run x local-api-install once to enter API ID/hash first."
    echo "找不到 ${LOCAL_API_ENV}。请先运行一次 x local-api-install 输入 API ID/hash。"
    exit 1
  }
  install_packages
  ensure_swap
  build_local_api
  write_service
  start_local_api
  echo
  echo "Local Bot API server is installed. / 本地 Bot API 服务已安装。"
  echo "Next step / 下一步: x local-api-switch"
}

install_background() {
  [ -f "${LOCAL_API_ENV}" ] || {
    echo "${LOCAL_API_ENV} not found. Run x local-api-install once to enter API ID/hash first."
    echo "找不到 ${LOCAL_API_ENV}。请先运行一次 x local-api-install 输入 API ID/hash。"
    exit 1
  }
  echo "Starting background install. SSH can disconnect safely now."
  echo "正在后台安装，现在 SSH 断开也没关系。"
  echo "Log / 日志: ${INSTALL_LOG}"
  nohup bash "$0" resume-install > "${INSTALL_LOG}" 2>&1 &
  echo "PID: $!"
  echo "Watch log / 查看日志: x local-api-install-log"
}

need_root

case "${1:-menu}" in
  menu) menu ;;
  install) install_all ;;
  install-bg|background) install_background ;;
  resume-install) install_without_prompt ;;
  install-log|log-install) tail -f "${INSTALL_LOG}" ;;
  switch|enable) switch_to_local_api ;;
  public|disable) switch_to_public_api ;;
  status|doctor) status ;;
  logs|log) journalctl -u "${LOCAL_API_NAME}" -f ;;
  *)
    echo "Usage / 用法:"
    echo "  x local-api"
    echo "  x local-api-install  # Install/update local Bot API / 安装或更新本地 Bot API"
    echo "  x local-api-install-bg   # Continue install in background / 后台继续安装"
    echo "  x local-api-install-log  # Follow background install log / 查看后台安装日志"
    echo "  x local-api-switch   # Switch to local original-quality mode / 切换到本地原画质模式"
    echo "  x local-api-status   # Show status / 查看状态"
    echo "  x local-api-logs     # Follow logs / 查看实时日志"
    echo "  x local-api-public   # Switch back to public API / 切回公网 API"
    exit 1
    ;;
esac
