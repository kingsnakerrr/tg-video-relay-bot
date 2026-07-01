#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
CONTROL_BIN="/usr/local/bin/x"
ALT_CONTROL_BIN="/usr/local/bin/tg-video-relay"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root."
    exit 1
  fi
}

usage() {
  cat <<EOF
Telegram Video Relay control

Usage:
  x                    Open menu
  x start              Start the bot
  x stop               Stop/pause the bot
  x pause              Same as stop
  x restart            Restart the bot
  x status             Show service status
  x logs               Follow live logs
  x cookies            Sync cookies.txt now
  x env                Edit .env config
  x update             Pull latest code and restart
  x reinstall          Run install.sh again
  x uninstall          Remove service, keep app files and .env
  x purge              Remove service and delete app directory
EOF
}

menu() {
  clear 2>/dev/null || true
  cat <<EOF
Telegram Video Relay

1) Start
2) Stop / Pause
3) Restart
4) Status
5) Logs
6) Sync cookies
7) Edit config
8) Update
9) Reinstall
10) Uninstall service, keep files
11) Purge everything
0) Exit
EOF
  echo
  read -r -p "Choose: " choice
  case "${choice}" in
    1) run start ;;
    2) run stop ;;
    3) run restart ;;
    4) run status ;;
    5) run logs ;;
    6) run cookies ;;
    7) run env ;;
    8) run update ;;
    9) run reinstall ;;
    10) run uninstall ;;
    11) run purge ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
}

stop_service() {
  systemctl stop "${APP_NAME}" 2>/dev/null || true
  systemctl disable "${APP_NAME}" 2>/dev/null || true
}

remove_service() {
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl reset-failed "${APP_NAME}" 2>/dev/null || true
}

run() {
  cmd="${1:-menu}"
  case "${cmd}" in
    menu)
      menu
      ;;
    start)
      need_root
      systemctl start "${APP_NAME}"
      systemctl status "${APP_NAME}" --no-pager
      ;;
    stop|pause)
      need_root
      systemctl stop "${APP_NAME}"
      echo "Stopped ${APP_NAME}."
      ;;
    restart)
      need_root
      systemctl restart "${APP_NAME}"
      systemctl status "${APP_NAME}" --no-pager
      ;;
    status)
      systemctl status "${APP_NAME}" --no-pager
      ;;
    logs|log)
      journalctl -u "${APP_NAME}" -f
      ;;
    cookies|cookie|sync-cookies)
      need_root
      cd "${APP_DIR}"
      "${APP_DIR}/.venv/bin/python" -m tg_video_relay_bot.cookie_sync
      ;;
    env|config)
      need_root
      "${EDITOR:-nano}" "${APP_DIR}/.env"
      echo "Saved. Run: x restart"
      ;;
    update)
      need_root
      if [ ! -d "${APP_DIR}/.git" ]; then
        echo "${APP_DIR} is not a Git checkout. Reinstall with install.sh."
        exit 1
      fi
      git -C "${APP_DIR}" fetch origin "${BRANCH}"
      git -C "${APP_DIR}" checkout "${BRANCH}"
      git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
      "${APP_DIR}/.venv/bin/python" -m pip install -r "${APP_DIR}/requirements.txt"
      if [ -f "${APP_DIR}/control.sh" ]; then
        install -m 755 "${APP_DIR}/control.sh" "${CONTROL_BIN}"
        install -m 755 "${APP_DIR}/control.sh" "${ALT_CONTROL_BIN}"
      fi
      systemctl restart "${APP_NAME}"
      systemctl status "${APP_NAME}" --no-pager
      ;;
    uninstall)
      need_root
      stop_service
      remove_service
      rm -f "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
      echo "Uninstalled service and control command."
      echo "Kept app files and config: ${APP_DIR}"
      ;;
    purge)
      need_root
      confirm="${2:-}"
      if [ "${confirm}" != "--yes" ]; then
        echo "This will stop the bot and delete ${APP_DIR}."
        read -r -p "Type DELETE to continue: " answer
        [ "${answer}" = "DELETE" ] || { echo "Cancelled."; exit 1; }
      fi
      stop_service
      remove_service
      rm -f "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
      rm -rf "${APP_DIR}"
      echo "Purged ${APP_NAME}."
      ;;
    reinstall)
      need_root
      if [ -f "${APP_DIR}/install.sh" ]; then
        bash "${APP_DIR}/install.sh"
      else
        bash <(curl -fsSL "https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/${BRANCH}/install.sh?ts=$(date +%s)")
      fi
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: ${cmd}"
      usage
      exit 1
      ;;
  esac
}

run "${1:-menu}" "${2:-}"
