#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
CONTROL_BIN="/usr/local/bin/x"
ALT_CONTROL_BIN="/usr/local/bin/tg-video-relay"
LOCAL_API_NAME="${LOCAL_API_NAME:-telegram-bot-api}"
LOCAL_API_ENV="${LOCAL_API_ENV:-/etc/telegram-bot-api.env}"
LOCAL_API_PORT="${LOCAL_API_PORT:-8081}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root. / 请用 root 运行。"
    exit 1
  fi
}

usage() {
  cat <<EOF
Telegram Video Relay control / Telegram 视频转发控制命令

Usage / 用法:
  x                    Open menu / 打开菜单
  x start              Start the bot / 启动机器人
  x stop               Stop/pause the bot / 停止或暂停机器人
  x pause              Same as stop / 同 stop
  x restart            Restart the bot / 重启机器人
  x status             Show service status / 查看服务状态
  x logs               Follow live logs / 查看实时日志
  x doctor             Diagnose service and submit API / 诊断服务和提交接口
  x mode               Show upload mode status / 查看上传模式状态
  x local              Switch to Local Bot API mode / 切换到本地原画质模式
  x public             Switch to public Bot API mode / 切回公网兼容模式
  x quality            Show original-quality upload settings / 查看原画质上传配置
  x local-api          Install/configure local Bot API server / 安装或配置本地 Bot API
  x local-api-install-bg Continue low-memory background install / 低内存后台继续安装本地 Bot API
  x fix-env            Add missing default .env keys / 补齐缺少的 .env 默认配置
  x test-submit URL    Submit one URL from the VPS itself / 在 VPS 本机测试提交链接
  x cookies            Sync cookies.txt now / 立即同步 cookies.txt
  x shortcut           Show iPhone Shortcut submit settings / 查看 iPhone 快捷指令配置
  x env                Edit .env config / 编辑 .env 配置
  x update             Pull latest code and restart / 更新代码并重启
  x reinstall          Run install.sh again / 重新执行安装脚本
  x uninstall          Remove service, keep app files and .env / 卸载服务，保留程序和 .env
  x purge              Remove service and delete app directory / 彻底删除服务和程序目录
EOF
}

menu() {
  clear 2>/dev/null || true
  current_mode="$(current_upload_mode_label)"
  local_status="$(local_api_short_status)"
  cat <<EOF
Telegram Video Relay / Telegram 视频转发

Current upload mode / 当前上传模式:
  ${current_mode}
Local Bot API / 本地 Bot API:
  ${local_status}

1) Start / 启动
2) Stop / Pause / 停止或暂停
3) Restart / 重启
4) Status / 状态
5) Doctor / 诊断
6) Logs / 日志
7) Upload mode status / 上传模式状态
8) Original-quality upload settings / 原画质上传配置
9) Local Bot API server / 本地 Bot API 服务
10) Fix missing .env defaults / 补齐缺少的 .env 默认配置
11) Test submit URL / 测试提交链接
12) Sync cookies / 同步 cookies
13) iPhone Shortcut settings / iPhone 快捷指令配置
14) Edit config / 编辑配置
15) Update / 更新
16) Reinstall / 重装
17) Uninstall service, keep files / 卸载服务但保留文件
18) Purge everything / 彻底删除
0) Exit / 退出
EOF
  echo
  read -r -p "Choose / 请选择: " choice
  case "${choice}" in
    1) run start ;;
    2) run stop ;;
    3) run restart ;;
    4) run status ;;
    5) run doctor ;;
    6) run logs ;;
    7) run mode ;;
    8) run quality ;;
    9) run local-api ;;
    10) run fix-env ;;
    11) read -r -p "URL: " test_url; run test-submit "${test_url}" ;;
    12) run cookies ;;
    13) run shortcut ;;
    14) run env ;;
    15) run update ;;
    16) run reinstall ;;
    17) run uninstall ;;
    18) run purge ;;
    0|q|Q) exit 0 ;;
    *) echo "Invalid choice. / 选择无效。"; exit 1 ;;
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

is_local_mode_selected() {
  base_url="$(env_value BOT_API_BASE_URL)"
  local_file_uri="$(env_value BOT_API_USE_LOCAL_FILE_URI)"
  [ "${local_file_uri}" = "true" ] || [ "${base_url}" = "http://127.0.0.1:${LOCAL_API_PORT}" ]
}

current_upload_mode_label() {
  if [ ! -f "${APP_DIR}/.env" ]; then
    echo "unknown, .env missing / 未知，找不到 .env"
    return
  fi
  if is_local_mode_selected; then
    echo "Local Bot API original-quality mode / 本地 Bot API 原画质模式"
  else
    echo "Public Bot API compatibility mode / 公网 Bot API 兼容模式"
  fi
}

local_api_short_status() {
  if systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null; then
    echo "service active / 服务运行中"
  elif [ -x /usr/local/bin/telegram-bot-api ]; then
    echo "installed, service not active / 已安装，服务未运行"
  elif [ -f "${LOCAL_API_ENV}" ]; then
    echo "credentials saved, server not installed / 已保存参数，服务未安装"
  else
    echo "not configured / 未配置"
  fi
}

yes_no() {
  if "$@"; then
    echo "yes / 是"
  else
    echo "no / 否"
  fi
}

mode_status() {
  ensure_env_defaults
  echo "== Current mode / 当前模式 =="
  current_mode="$(current_upload_mode_label)"
  echo "${current_mode}"
  echo

  echo "== Public Bot API mode / 公网 Bot API 模式 =="
  echo "Available / 可用: yes / 是"
  if is_local_mode_selected; then
    echo "Current / 当前正在用: no / 否"
  else
    echo "Current / 当前正在用: yes / 是"
  fi
  echo "Upload limit / 上传限制: about 50 MB, auto-compress recommended / 约 50MB，建议自动压缩"
  echo "Switch command / 切换命令: x local-api-public"
  echo

  echo "== Local Bot API original-quality mode / 本地 Bot API 原画质模式 =="
  if is_local_mode_selected; then
    echo "Current / 当前正在用: yes / 是"
  else
    echo "Current / 当前正在用: no / 否"
  fi
  printf 'API credentials saved / API ID 和 hash 已保存: '
  [ -f "${LOCAL_API_ENV}" ] && echo "yes / 是" || echo "no / 否"
  printf 'Binary installed / 程序已安装: '
  [ -x /usr/local/bin/telegram-bot-api ] && echo "yes / 是" || echo "no / 否"
  printf 'Service active / 服务运行中: '
  systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null && echo "yes / 是" || echo "no / 否"
  printf 'Port listening / 端口监听: '
  ss -lnt 2>/dev/null | grep -q ":${LOCAL_API_PORT} " && echo "yes / 是" || echo "no / 否"
  echo "Upload limit / 上传限制: up to about 2000 MB, no auto-compress / 最高约 2000MB，不自动压缩"
  echo "Switch command / 切换命令: x local-api-switch"
  echo

  echo "== Current .env upload settings / 当前 .env 上传配置 =="
  printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL)"
  printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI)"
  printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
  printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
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

ensure_upload_env() {
  env_file="${APP_DIR}/.env"
  [ -f "${env_file}" ] || return
  grep -q '^BOT_API_BASE_URL=' "${env_file}" || printf 'BOT_API_BASE_URL=https://api.telegram.org\n' >> "${env_file}"
  grep -q '^BOT_API_USE_LOCAL_FILE_URI=' "${env_file}" || printf 'BOT_API_USE_LOCAL_FILE_URI=false\n' >> "${env_file}"
  grep -q '^MAX_UPLOAD_MB=' "${env_file}" || printf 'MAX_UPLOAD_MB=49\n' >> "${env_file}"
  grep -q '^AUTO_COMPRESS=' "${env_file}" || printf 'AUTO_COMPRESS=true\n' >> "${env_file}"
  grep -q '^COMPRESS_AUDIO_KBPS=' "${env_file}" || printf 'COMPRESS_AUDIO_KBPS=96\n' >> "${env_file}"
  grep -q '^COMPRESS_MIN_VIDEO_KBPS=' "${env_file}" || printf 'COMPRESS_MIN_VIDEO_KBPS=60\n' >> "${env_file}"
}

ensure_env_defaults() {
  ensure_upload_env
  ensure_submit_env
}

run() {
  cmd="${1:-menu}"
  case "${cmd}" in
    menu)
      menu
      ;;
    start)
      need_root
      ensure_env_defaults
      systemctl start "${APP_NAME}"
      systemctl status "${APP_NAME}" --no-pager
      ;;
    stop|pause)
      need_root
      systemctl stop "${APP_NAME}"
      echo "Stopped ${APP_NAME}. / 已停止 ${APP_NAME}。"
      ;;
    restart)
      need_root
      ensure_env_defaults
      systemctl restart "${APP_NAME}"
      systemctl status "${APP_NAME}" --no-pager
      ;;
    status)
      systemctl status "${APP_NAME}" --no-pager
      ;;
    mode|modes)
      need_root
      mode_status
      ;;
    doctor)
      need_root
      ensure_env_defaults
      port="$(env_value SUBMIT_API_PORT)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      secret="$(env_value SUBMIT_API_SECRET)"
      [ -n "${port}" ] || port="8787"
      echo "== Version / 版本 =="
      grep 'INSTALLER_VERSION=' "${APP_DIR}/install.sh" 2>/dev/null || echo "install.sh not found"
      echo
      echo "== Submit API .env / 提交接口配置 =="
      printf 'SUBMIT_API_ENABLED=%s\n' "${enabled:-}"
      printf 'SUBMIT_API_PORT=%s\n' "${port}"
      if [ -n "${secret}" ]; then
        echo "SUBMIT_API_SECRET=set / 已设置"
      else
        echo "SUBMIT_API_SECRET=missing / 缺失"
      fi
      echo
      echo "== Upload API .env / 上传接口配置 =="
      printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL)"
      printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI)"
      printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
      printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
      echo
      echo "== Service / 服务 =="
      systemctl is-active "${APP_NAME}" || true
      systemctl status "${APP_NAME}" --no-pager -n 5 || true
      echo
      echo "== Listening port / 监听端口 =="
      ss -lntp 2>/dev/null | grep ":${port} " || echo "Not listening on ${port} / 未监听 ${port}"
      echo
      echo "== Local health / 本地健康检查 =="
      curl -fsS "http://127.0.0.1:${port}/health" || echo "Health check failed / 健康检查失败"
      echo
      echo
      echo "If the port is not listening, run / 如果端口没有监听，执行:"
      echo "  x update"
      echo "  x restart"
      echo "  x logs"
      ;;
    quality)
      env_file="${APP_DIR}/.env"
      [ -f "${env_file}" ] || { echo "${env_file} not found."; exit 1; }
      mode_status
      echo
      echo "Public Telegram Bot API mode / 公网 Bot API 模式:"
      echo "  MAX_UPLOAD_MB=49"
      echo "  AUTO_COMPRESS=true"
      echo
      echo "Original-quality large upload mode requires telegram-bot-api running on this VPS."
      echo "原画质大文件模式需要 VPS 上运行 telegram-bot-api。"
      echo "After it is running locally, set these in x env / 本地服务运行后，在 x env 里设置:"
      echo "  BOT_API_BASE_URL=http://127.0.0.1:8081"
      echo "  BOT_API_USE_LOCAL_FILE_URI=true"
      echo "  MAX_UPLOAD_MB=1900"
      echo "  AUTO_COMPRESS=false"
      echo
      echo "Then run / 然后执行: x restart"
      echo "See / 说明文档: LOCAL_BOT_API.md"
      ;;
    fix-env)
      need_root
      ensure_env_defaults
      echo "Missing default .env keys have been added. / 已补齐缺少的 .env 默认配置。"
      echo "Check with / 检查: x quality"
      echo "Restart with / 重启: x restart"
      ;;
    local-api)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh"
      ;;
    local-api-install)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" install
      ;;
    local-api-install-bg|local-api-background)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" install-bg
      ;;
    local-api-install-log)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" install-log
      ;;
    local-api-switch|local-api-enable)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" switch
      ;;
    local)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" switch
      ;;
    local-api-status)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" status
      ;;
    local-api-logs)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" logs
      ;;
    local-api-public|local-api-disable)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" public
      ;;
    public)
      need_root
      bash "${APP_DIR}/install_local_bot_api.sh" public
      ;;
    logs|log)
      journalctl -u "${APP_NAME}" -f
      ;;
    test-submit|test)
      need_root
      ensure_env_defaults
      port="$(env_value SUBMIT_API_PORT)"
      secret="$(env_value SUBMIT_API_SECRET)"
      url="${2:-}"
      [ -n "${port}" ] || port="8787"
      if [ -z "${url}" ]; then
        echo "Usage / 用法: x test-submit 'https://x.com/.../status/...'"
        exit 1
      fi
      curl -fsS -G "http://127.0.0.1:${port}/submit" \
        --data-urlencode "secret=${secret}" \
        --data-urlencode "url=${url}"
      echo
      echo "Queued. Watch logs with: x logs / 已加入队列，用 x logs 查看日志。"
      ;;
    cookies|cookie|sync-cookies)
      need_root
      cd "${APP_DIR}"
      "${APP_DIR}/.venv/bin/python" -m tg_video_relay_bot.cookie_sync
      ;;
    shortcut|submit)
      need_root
      ensure_env_defaults
      port="$(env_value SUBMIT_API_PORT)"
      secret="$(env_value SUBMIT_API_SECRET)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      host_hint="$(hostname -I 2>/dev/null | awk '{print $1}')"
      [ -n "${port}" ] || port="8787"
      [ -n "${host_hint}" ] || host_hint="YOUR_VPS_IP_OR_DOMAIN"
      echo "Submit API enabled / 提交接口启用: ${enabled:-unknown}"
      echo "Shortcut URL / 快捷指令 URL:"
      echo "  http://${host_hint}:${port}/submit"
      echo
      echo "Shortcut form fields / 快捷指令表单字段:"
      echo "  secret = ${secret}"
      echo "  url    = Shortcut Input URL"
      echo
      echo "Local test / 本地测试:"
      echo "  curl -G 'http://127.0.0.1:${port}/submit' --data-urlencode 'secret=${secret}' --data-urlencode 'url=https://x.com/example/status/123'"
      echo
      echo "For iPhone outside your VPS, open TCP port ${port} or use HTTPS reverse proxy."
      echo "如果 iPhone 不在 VPS 本机，需要放行 TCP ${port} 或使用 HTTPS 反向代理。"
      ;;
    env|config)
      need_root
      "${EDITOR:-nano}" "${APP_DIR}/.env"
      echo "Saved. Run: x restart / 已保存，执行 x restart 重启。"
      ;;
    update)
      need_root
      if [ ! -d "${APP_DIR}/.git" ]; then
        echo "${APP_DIR} is not a Git checkout. Reinstall with install.sh."
        echo "${APP_DIR} 不是 Git 项目，请用 install.sh 重新安装。"
        exit 1
      fi
      git -C "${APP_DIR}" fetch origin "${BRANCH}"
      git -C "${APP_DIR}" checkout "${BRANCH}"
      git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
      "${APP_DIR}/.venv/bin/python" -m pip install -r "${APP_DIR}/requirements.txt"
      ensure_env_defaults
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
      echo "Uninstalled service and control command. / 已卸载服务和控制命令。"
      echo "Kept app files and config / 保留程序和配置: ${APP_DIR}"
      ;;
    purge)
      need_root
      confirm="${2:-}"
      if [ "${confirm}" != "--yes" ]; then
        echo "This will stop the bot and delete ${APP_DIR}."
        echo "这会停止机器人并删除 ${APP_DIR}。"
        read -r -p "Type DELETE to continue / 输入 DELETE 继续: " answer
        [ "${answer}" = "DELETE" ] || { echo "Cancelled. / 已取消。"; exit 1; }
      fi
      stop_service
      remove_service
      rm -f "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
      rm -rf "${APP_DIR}"
      echo "Purged ${APP_NAME}. / 已彻底删除 ${APP_NAME}。"
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
      echo "Unknown command: ${cmd} / 未知命令: ${cmd}"
      usage
      exit 1
      ;;
  esac
}

run "${1:-menu}" "${2:-}"
