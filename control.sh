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
  x doctor             Diagnose service and submit API
  x quality            Show original-quality upload settings
  x test-submit URL    Submit one URL from the VPS itself
  x cookies            Sync cookies.txt now
  x shortcut           Show iPhone Shortcut submit settings
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
5) Doctor
6) Logs
7) Original-quality upload settings
8) Test submit URL
9) Sync cookies
10) iPhone Shortcut settings
11) Edit config
12) Update
13) Reinstall
14) Uninstall service, keep files
15) Purge everything
0) Exit
EOF
  echo
  read -r -p "Choose: " choice
  case "${choice}" in
    1) run start ;;
    2) run stop ;;
    3) run restart ;;
    4) run status ;;
    5) run doctor ;;
    6) run logs ;;
    7) run quality ;;
    8) read -r -p "URL: " test_url; run test-submit "${test_url}" ;;
    9) run cookies ;;
    10) run shortcut ;;
    11) run env ;;
    12) run update ;;
    13) run reinstall ;;
    14) run uninstall ;;
    15) run purge ;;
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

env_value() {
  key="$1"
  if [ ! -f "${APP_DIR}/.env" ]; then
    return
  fi
  grep -E "^${key}=" "${APP_DIR}/.env" | tail -n 1 | cut -d= -f2-
}

generate_secret() {
  if [ -x "${APP_DIR}/.venv/bin/python" ]; then
    "${APP_DIR}/.venv/bin/python" -c 'import secrets; print(secrets.token_urlsafe(32))'
  else
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
  fi
}

ensure_submit_env() {
  env_file="${APP_DIR}/.env"
  [ -f "${env_file}" ] || return
  grep -q '^SUBMIT_API_ENABLED=' "${env_file}" || printf 'SUBMIT_API_ENABLED=true\n' >> "${env_file}"
  grep -q '^SUBMIT_API_HOST=' "${env_file}" || printf 'SUBMIT_API_HOST=0.0.0.0\n' >> "${env_file}"
  grep -q '^SUBMIT_API_PORT=' "${env_file}" || printf 'SUBMIT_API_PORT=8787\n' >> "${env_file}"
  if ! grep -q '^SUBMIT_API_SECRET=' "${env_file}" || grep -q '^SUBMIT_API_SECRET=$' "${env_file}"; then
    new_secret="$(generate_secret)"
    if grep -q '^SUBMIT_API_SECRET=' "${env_file}"; then
      sed -i "s|^SUBMIT_API_SECRET=.*|SUBMIT_API_SECRET=${new_secret}|" "${env_file}"
    else
      printf 'SUBMIT_API_SECRET=%s\n' "${new_secret}" >> "${env_file}"
    fi
  fi
  grep -q '^SUBMIT_NOTIFY_CHAT_ID=' "${env_file}" || printf 'SUBMIT_NOTIFY_CHAT_ID=\n' >> "${env_file}"
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
    doctor)
      need_root
      ensure_submit_env
      port="$(env_value SUBMIT_API_PORT)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      secret="$(env_value SUBMIT_API_SECRET)"
      [ -n "${port}" ] || port="8787"
      echo "== Version =="
      grep 'INSTALLER_VERSION=' "${APP_DIR}/install.sh" 2>/dev/null || echo "install.sh not found"
      echo
      echo "== Submit API .env =="
      printf 'SUBMIT_API_ENABLED=%s\n' "${enabled:-}"
      printf 'SUBMIT_API_PORT=%s\n' "${port}"
      if [ -n "${secret}" ]; then
        echo "SUBMIT_API_SECRET=set"
      else
        echo "SUBMIT_API_SECRET=missing"
      fi
      echo
      echo "== Upload API .env =="
      printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL)"
      printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI)"
      printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
      printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
      echo
      echo "== Service =="
      systemctl is-active "${APP_NAME}" || true
      systemctl status "${APP_NAME}" --no-pager -n 5 || true
      echo
      echo "== Listening port =="
      ss -lntp 2>/dev/null | grep ":${port} " || echo "Not listening on ${port}"
      echo
      echo "== Local health =="
      curl -fsS "http://127.0.0.1:${port}/health" || echo "Health check failed"
      echo
      echo
      echo "If the port is not listening, run:"
      echo "  x update"
      echo "  x restart"
      echo "  x logs"
      ;;
    quality)
      env_file="${APP_DIR}/.env"
      [ -f "${env_file}" ] || { echo "${env_file} not found."; exit 1; }
      echo "== Current upload settings =="
      printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL)"
      printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI)"
      printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
      printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
      printf 'UPLOAD_MODE=%s\n' "$(env_value UPLOAD_MODE)"
      echo
      echo "Public Telegram Bot API mode:"
      echo "  MAX_UPLOAD_MB=49"
      echo "  AUTO_COMPRESS=true"
      echo
      echo "Original-quality large upload mode requires telegram-bot-api running on this VPS."
      echo "After it is running locally, set these in x env:"
      echo "  BOT_API_BASE_URL=http://127.0.0.1:8081"
      echo "  BOT_API_USE_LOCAL_FILE_URI=true"
      echo "  MAX_UPLOAD_MB=1900"
      echo "  AUTO_COMPRESS=false"
      echo
      echo "Then run: x restart"
      echo "See: LOCAL_BOT_API.md"
      ;;
    logs|log)
      journalctl -u "${APP_NAME}" -f
      ;;
    test-submit|test)
      need_root
      ensure_submit_env
      port="$(env_value SUBMIT_API_PORT)"
      secret="$(env_value SUBMIT_API_SECRET)"
      url="${2:-}"
      [ -n "${port}" ] || port="8787"
      if [ -z "${url}" ]; then
        echo "Usage: x test-submit 'https://x.com/.../status/...'"
        exit 1
      fi
      curl -fsS -G "http://127.0.0.1:${port}/submit" \
        --data-urlencode "secret=${secret}" \
        --data-urlencode "url=${url}"
      echo
      echo "Queued. Watch logs with: x logs"
      ;;
    cookies|cookie|sync-cookies)
      need_root
      cd "${APP_DIR}"
      "${APP_DIR}/.venv/bin/python" -m tg_video_relay_bot.cookie_sync
      ;;
    shortcut|submit)
      need_root
      ensure_submit_env
      port="$(env_value SUBMIT_API_PORT)"
      secret="$(env_value SUBMIT_API_SECRET)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      host_hint="$(hostname -I 2>/dev/null | awk '{print $1}')"
      [ -n "${port}" ] || port="8787"
      [ -n "${host_hint}" ] || host_hint="YOUR_VPS_IP_OR_DOMAIN"
      echo "Submit API enabled: ${enabled:-unknown}"
      echo "Shortcut URL:"
      echo "  http://${host_hint}:${port}/submit"
      echo
      echo "Shortcut form fields:"
      echo "  secret = ${secret}"
      echo "  url    = Shortcut Input URL"
      echo
      echo "Local test:"
      echo "  curl -G 'http://127.0.0.1:${port}/submit' --data-urlencode 'secret=${secret}' --data-urlencode 'url=https://x.com/example/status/123'"
      echo
      echo "For iPhone outside your VPS, open TCP port ${port} or use HTTPS reverse proxy."
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
      ensure_submit_env
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
