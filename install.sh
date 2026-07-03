#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
CONTROL_BIN="/usr/local/bin/x"
ALT_CONTROL_BIN="/usr/local/bin/tg-video-relay"
INSTALLER_VERSION="2026-07-03.1"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

has_project_files() {
  local dir="$1"
  [ -f "${dir}/requirements.txt" ] && [ -d "${dir}/tg_video_relay_bot" ]
}

dir_is_not_empty() {
  local dir="$1"
  local first_entry=""
  [ -d "${dir}" ] || return 1
  first_entry="$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
  [ -n "${first_entry}" ]
}

ask_required() {
  local prompt="$1"
  local value=""
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt}: " value
  done
  printf '%s' "${value}"
}

generate_secret() {
  python -c 'import secrets; print(secrets.token_urlsafe(32))'
}

if [ "$(id -u)" -ne 0 ]; then
  die "Please run as root, for example: sudo bash install.sh"
fi

echo "Telegram Video Relay installer ${INSTALLER_VERSION}"

case "${1:-}" in
  uninstall)
    step "Uninstalling service"
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    systemctl disable "${APP_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
    systemctl daemon-reload
    systemctl reset-failed "${APP_NAME}" 2>/dev/null || true
    echo "Uninstalled service. Kept app files: ${APP_DIR}"
    exit 0
    ;;
  purge)
    if [ "${2:-}" != "--yes" ]; then
      echo "This will stop the bot and delete ${APP_DIR}."
      read -r -p "Type DELETE to continue: " answer
      [ "${answer}" = "DELETE" ] || { echo "Cancelled."; exit 1; }
    fi
    step "Purging install"
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    systemctl disable "${APP_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
    rm -rf "${APP_DIR}"
    systemctl daemon-reload
    systemctl reset-failed "${APP_NAME}" 2>/dev/null || true
    echo "Purged ${APP_NAME}."
    exit 0
    ;;
esac

step "Installing system packages"
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y git curl ca-certificates python3 python3-venv python3-pip ffmpeg
else
  die "This installer currently supports Debian/Ubuntu with apt."
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [ -n "${SCRIPT_SOURCE}" ] && [ -f "${SCRIPT_SOURCE}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
fi

step "Preparing app directory: ${APP_DIR}"
mkdir -p "$(dirname "${APP_DIR}")"

if [ -n "${SCRIPT_DIR}" ] && has_project_files "${SCRIPT_DIR}"; then
  mkdir -p "${APP_DIR}"
  if [ "${SCRIPT_DIR}" != "${APP_DIR}" ]; then
    step "Copying local project files"
    tar \
      --exclude='./.env' \
      --exclude='./downloads' \
      --exclude='./.venv' \
      --exclude='./__pycache__' \
      -C "${SCRIPT_DIR}" -cf - . | tar -C "${APP_DIR}" -xf -
  fi
elif [ -d "${APP_DIR}/.git" ]; then
  step "Updating existing GitHub checkout"
  git -C "${APP_DIR}" fetch origin "${BRANCH}"
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
elif dir_is_not_empty "${APP_DIR}"; then
  if has_project_files "${APP_DIR}"; then
    step "Using existing project files"
  else
    BACKUP_DIR="${APP_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    step "${APP_DIR} exists but is not a valid install. Moving it to ${BACKUP_DIR}"
    mv "${APP_DIR}" "${BACKUP_DIR}"
    step "Cloning project from GitHub"
    git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
  fi
else
  step "Cloning project from GitHub"
  git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}"
has_project_files "${APP_DIR}" || die "Project files were not found in ${APP_DIR}."

step "Creating Python virtual environment"
"${PYTHON_BIN}" -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if [ ! -f .env ]; then
  step "Creating .env"
  BOT_TOKEN="$(ask_required "Telegram Bot Token")"
  TARGET_CHAT_IDS="$(ask_required "Target channel/group IDs, comma separated")"
  ALLOWED_USER_IDS="$(ask_required "Admin Telegram user IDs, comma separated")"
  SUBMIT_API_SECRET="$(generate_secret)"

  cat > .env <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
BOT_API_BASE_URL=https://api.telegram.org
BOT_API_USE_LOCAL_FILE_URI=false
TARGET_CHAT_IDS=${TARGET_CHAT_IDS}
ALLOWED_USER_IDS=${ALLOWED_USER_IDS}
DOWNLOAD_DIR=downloads
DOWNLOAD_FORMAT=bv*+ba/best
MERGE_OUTPUT_FORMAT=mp4
MAX_FILE_MB=1900
MAX_UPLOAD_MB=49
AUTO_COMPRESS=true
COMPRESS_AUDIO_KBPS=96
COMPRESS_MIN_VIDEO_KBPS=60
COOKIES_FILE=${APP_DIR}/cookies.txt
COOKIE_SYNC_URL=
COOKIE_SYNC_INTERVAL_MINUTES=360
UPLOAD_MODE=video
DELETE_AFTER_ALL_UPLOADS=true
BOT_API_TIMEOUT=30
UPLOAD_TIMEOUT=1800
POLL_TIMEOUT=50
WORKER_COUNT=1
SUBMIT_API_ENABLED=true
SUBMIT_API_HOST=0.0.0.0
SUBMIT_API_PORT=8787
SUBMIT_API_SECRET=${SUBMIT_API_SECRET}
SUBMIT_NOTIFY_CHAT_ID=
EOF_ENV
else
  step "Existing .env found, keeping it"
fi

grep -q '^MAX_UPLOAD_MB=' .env || printf '\nMAX_UPLOAD_MB=49\n' >> .env
grep -q '^BOT_API_BASE_URL=' .env || printf 'BOT_API_BASE_URL=https://api.telegram.org\n' >> .env
grep -q '^BOT_API_USE_LOCAL_FILE_URI=' .env || printf 'BOT_API_USE_LOCAL_FILE_URI=false\n' >> .env
grep -q '^AUTO_COMPRESS=' .env || printf 'AUTO_COMPRESS=true\n' >> .env
grep -q '^COMPRESS_AUDIO_KBPS=' .env || printf 'COMPRESS_AUDIO_KBPS=96\n' >> .env
grep -q '^COMPRESS_MIN_VIDEO_KBPS=' .env || printf 'COMPRESS_MIN_VIDEO_KBPS=60\n' >> .env
if grep -q '^COOKIES_FILE=$' .env; then
  sed -i "s|^COOKIES_FILE=$|COOKIES_FILE=${APP_DIR}/cookies.txt|" .env
fi
grep -q '^COOKIES_FILE=' .env || printf 'COOKIES_FILE=%s/cookies.txt\n' "${APP_DIR}" >> .env
grep -q '^COOKIE_SYNC_URL=' .env || printf 'COOKIE_SYNC_URL=\n' >> .env
grep -q '^COOKIE_SYNC_INTERVAL_MINUTES=' .env || printf 'COOKIE_SYNC_INTERVAL_MINUTES=360\n' >> .env
grep -q '^SUBMIT_API_ENABLED=' .env || printf 'SUBMIT_API_ENABLED=true\n' >> .env
grep -q '^SUBMIT_API_HOST=' .env || printf 'SUBMIT_API_HOST=0.0.0.0\n' >> .env
grep -q '^SUBMIT_API_PORT=' .env || printf 'SUBMIT_API_PORT=8787\n' >> .env
if ! grep -q '^SUBMIT_API_SECRET=' .env || grep -q '^SUBMIT_API_SECRET=$' .env; then
  SUBMIT_API_SECRET="$(generate_secret)"
  if grep -q '^SUBMIT_API_SECRET=' .env; then
    sed -i "s|^SUBMIT_API_SECRET=.*|SUBMIT_API_SECRET=${SUBMIT_API_SECRET}|" .env
  else
    printf 'SUBMIT_API_SECRET=%s\n' "${SUBMIT_API_SECRET}" >> .env
  fi
fi
grep -q '^SUBMIT_NOTIFY_CHAT_ID=' .env || printf 'SUBMIT_NOTIFY_CHAT_ID=\n' >> .env
if [ -f "${APP_DIR}/cookies.txt" ]; then
  chmod 600 "${APP_DIR}/cookies.txt"
fi

step "Writing systemd service"
cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=Telegram Video Relay Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/.venv/bin/python -m tg_video_relay_bot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

step "Installing control command"
if [ -f "${APP_DIR}/control.sh" ]; then
  install -m 755 "${APP_DIR}/control.sh" "${CONTROL_BIN}"
  install -m 755 "${APP_DIR}/control.sh" "${ALT_CONTROL_BIN}"
else
  echo "WARNING: control.sh not found; skipping ${CONTROL_BIN}"
fi

step "Starting service"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

echo
echo "Installed successfully."
echo "App dir: ${APP_DIR}"
echo "Menu:    x"
echo "Status:  x status"
echo "Logs:    x logs"
echo "Stop:    x stop"
echo "Start:   x start"
echo "Shortcut:x shortcut"
echo "Remove:  x uninstall"
echo "Update:  bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)"
