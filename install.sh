#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

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
  [[ -f "${dir}/requirements.txt" && -d "${dir}/tg_video_relay_bot" ]]
}

ask_required() {
  local prompt="$1"
  local value=""
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt}: " value
  done
  printf '%s' "${value}"
}

if [[ "$(id -u)" -ne 0 ]]; then
  die "Please run as root, for example: sudo bash install.sh"
fi

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
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
fi

step "Preparing app directory: ${APP_DIR}"
mkdir -p "$(dirname "${APP_DIR}")"

if [[ -n "${SCRIPT_DIR}" && has_project_files "${SCRIPT_DIR}" ]]; then
  mkdir -p "${APP_DIR}"
  if [[ "${SCRIPT_DIR}" != "${APP_DIR}" ]]; then
    step "Copying local project files"
    tar \
      --exclude='./.env' \
      --exclude='./downloads' \
      --exclude='./.venv' \
      --exclude='./__pycache__' \
      -C "${SCRIPT_DIR}" -cf - . | tar -C "${APP_DIR}" -xf -
  fi
elif [[ -d "${APP_DIR}/.git" ]]; then
  step "Updating existing GitHub checkout"
  git -C "${APP_DIR}" fetch origin "${BRANCH}"
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
elif [[ -d "${APP_DIR}" && -n "$(ls -A "${APP_DIR}" 2>/dev/null || true)" ]]; then
  if has_project_files "${APP_DIR}"; then
    step "Using existing project files"
  else
    die "${APP_DIR} already exists and is not empty. Move it away or run with APP_DIR=/another/path."
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

if [[ ! -f .env ]]; then
  step "Creating .env"
  BOT_TOKEN="$(ask_required "Telegram Bot Token")"
  TARGET_CHAT_IDS="$(ask_required "Target channel/group IDs, comma separated")"
  ALLOWED_USER_IDS="$(ask_required "Admin Telegram user IDs, comma separated")"

  cat > .env <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
TARGET_CHAT_IDS=${TARGET_CHAT_IDS}
ALLOWED_USER_IDS=${ALLOWED_USER_IDS}
DOWNLOAD_DIR=downloads
DOWNLOAD_FORMAT=bv*+ba/best
MERGE_OUTPUT_FORMAT=mp4
MAX_FILE_MB=1900
COOKIES_FILE=
UPLOAD_MODE=video
DELETE_AFTER_ALL_UPLOADS=true
BOT_API_TIMEOUT=30
UPLOAD_TIMEOUT=1800
POLL_TIMEOUT=50
WORKER_COUNT=1
EOF_ENV
else
  step "Existing .env found, keeping it"
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

step "Starting service"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

echo
echo "Installed successfully."
echo "App dir: ${APP_DIR}"
echo "Status:  systemctl status ${APP_NAME}"
echo "Logs:    journalctl -u ${APP_NAME} -f"
echo "Update:  bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)"
