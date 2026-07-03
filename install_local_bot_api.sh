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
BUILD_JOBS="${BUILD_JOBS:-2}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root."
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
  if [ -n "${current_id}" ]; then
    read -r -p "API ID [keep current ${current_id}]: " api_id
    api_id="${api_id:-${current_id}}"
  else
    read -r -p "API ID: " api_id
  fi

  if [ -n "${current_hash}" ]; then
    read -r -s -p "API hash [press Enter to keep current]: " api_hash
    echo
    api_hash="${api_hash:-${current_hash}}"
  else
    read -r -s -p "API hash: " api_hash
    echo
  fi

  [ -n "${api_id}" ] || { echo "API ID is required."; exit 1; }
  [ -n "${api_hash}" ] || { echo "API hash is required."; exit 1; }

  cat > "${LOCAL_API_ENV}" <<EOF_ENV
TELEGRAM_API_ID=${api_id}
TELEGRAM_API_HASH=${api_hash}
EOF_ENV
  chmod 600 "${LOCAL_API_ENV}"
}

install_packages() {
  step "Installing build packages"
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y git curl ca-certificates build-essential cmake gperf zlib1g-dev libssl-dev libreadline-dev
  else
    echo "This installer currently supports Debian/Ubuntu with apt."
    exit 1
  fi
}

build_local_api() {
  step "Downloading Telegram Local Bot API Server"
  if [ -d "${LOCAL_API_SRC}/.git" ]; then
    git -C "${LOCAL_API_SRC}" fetch origin
    git -C "${LOCAL_API_SRC}" pull --ff-only
    git -C "${LOCAL_API_SRC}" submodule update --init --recursive
  else
    mkdir -p "$(dirname "${LOCAL_API_SRC}")"
    git clone --recursive "${LOCAL_API_REPO}" "${LOCAL_API_SRC}"
  fi

  step "Building telegram-bot-api"
  mkdir -p "${LOCAL_API_BUILD}"
  cmake -S "${LOCAL_API_SRC}" -B "${LOCAL_API_BUILD}" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
  cmake --build "${LOCAL_API_BUILD}" --target install -j"${BUILD_JOBS}"
}

write_service() {
  step "Writing systemd service"
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
  step "Starting local Bot API service"
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
    echo "BOT_TOKEN not found in ${APP_DIR}/.env"
    return 1
  fi
  curl -fsS "http://${LOCAL_API_HOST}:${LOCAL_API_PORT}/bot${token}/getMe"
}

switch_to_local_api() {
  step "Switching relay bot to local Bot API"
  [ -f "${APP_DIR}/.env" ] || { echo "${APP_DIR}/.env not found."; exit 1; }
  token="$(bot_token)"
  [ -n "${token}" ] || { echo "BOT_TOKEN not found in ${APP_DIR}/.env"; exit 1; }

  systemctl stop "${APP_NAME}" 2>/dev/null || true
  echo "Logging out from public Telegram Bot API. This is expected before local mode."
  curl -fsS "https://api.telegram.org/bot${token}/logOut" || true
  echo

  echo "Testing local Bot API..."
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
  step "Switching relay bot back to public Telegram Bot API"
  [ -f "${APP_DIR}/.env" ] || { echo "${APP_DIR}/.env not found."; exit 1; }
  set_env_value "${APP_DIR}/.env" BOT_API_BASE_URL "https://api.telegram.org"
  set_env_value "${APP_DIR}/.env" BOT_API_USE_LOCAL_FILE_URI "false"
  set_env_value "${APP_DIR}/.env" MAX_UPLOAD_MB "49"
  set_env_value "${APP_DIR}/.env" AUTO_COMPRESS "true"
  systemctl restart "${APP_NAME}"
  systemctl status "${APP_NAME}" --no-pager -n 10 || true
}

status() {
  echo "== Local Bot API service =="
  systemctl is-active "${LOCAL_API_NAME}" || true
  systemctl status "${LOCAL_API_NAME}" --no-pager -n 8 || true
  echo
  echo "== Listening port =="
  ss -lntp 2>/dev/null | grep ":${LOCAL_API_PORT} " || echo "Not listening on ${LOCAL_API_PORT}"
  echo
  echo "== Relay upload settings =="
  printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL "${APP_DIR}/.env")"
  printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI "${APP_DIR}/.env")"
  printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB "${APP_DIR}/.env")"
  printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS "${APP_DIR}/.env")"
  echo
  echo "== Local getMe test =="
  check_local_api || true
  echo
}

menu() {
  cat <<EOF
Local Telegram Bot API Server

1) Install / update local Bot API server
2) Switch relay bot to local original-quality mode
3) Show status
4) Logs
5) Switch relay bot back to public API
0) Exit
EOF
  echo
  read -r -p "Choose: " choice
  case "${choice}" in
    1) install_all ;;
    2) switch_to_local_api ;;
    3) status ;;
    4) journalctl -u "${LOCAL_API_NAME}" -f ;;
    5) switch_to_public_api ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
}

install_all() {
  install_packages
  write_local_env
  build_local_api
  write_service
  start_local_api
  echo
  echo "Local Bot API server is installed."
  echo "Next step: x local-api-switch"
}

need_root

case "${1:-menu}" in
  menu) menu ;;
  install) install_all ;;
  switch|enable) switch_to_local_api ;;
  public|disable) switch_to_public_api ;;
  status|doctor) status ;;
  logs|log) journalctl -u "${LOCAL_API_NAME}" -f ;;
  *)
    echo "Usage:"
    echo "  x local-api"
    echo "  x local-api-install"
    echo "  x local-api-switch"
    echo "  x local-api-status"
    echo "  x local-api-logs"
    echo "  x local-api-public"
    exit 1
    ;;
esac
