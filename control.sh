#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_VERSION="v62"
APP_DIR="${APP_DIR:-/opt/tg-video-relay-bot}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
CONTROL_BIN="/usr/local/bin/x"
ALT_CONTROL_BIN="/usr/local/bin/tg-video-relay"
LOCAL_API_NAME="${LOCAL_API_NAME:-telegram-bot-api}"
LOCAL_API_ENV="${LOCAL_API_ENV:-/etc/telegram-bot-api.env}"
LOCAL_API_PORT="${LOCAL_API_PORT:-8081}"
DEFAULT_DOWNLOAD_FORMAT='bv*+ba/best'
OLD_1080P_DOWNLOAD_FORMAT='bv*[height<=1080][ext=mp4]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]/best[height<=1080]/best'

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root. / 请用 root 运行。"
    exit 1
  fi
}

usage() {
  cat <<EOF
Telegram Video Relay control ${APP_VERSION} / Telegram 视频转发控制命令 ${APP_VERSION}

Usage / 用法:
  x                    Open menu / 打开菜单
  x start              Start the bot / 启动机器人
  x stop               Stop/pause the bot / 停止或暂停机器人
  x pause              Same as stop / 同 stop
  x restart            Restart the bot / 重启机器人
  x status             Show service status / 查看服务状态
  x logs               Follow live logs / 查看实时日志
  x logs-recent        Show recent logs / 查看最近日志
  x doctor             Diagnose service and submit API / 诊断服务和提交接口
  x ytdlp-update       Update yt-dlp downloader / 更新 yt-dlp 下载器
  x ytdlp-version      Show yt-dlp version / 查看 yt-dlp 版本
  x switch-mode        Switch upload mode / 切换上传模式
  x cookies-test       Test X and YouTube cookies / 检测 X 和 YouTube cookies
  x test-submit URL    Submit one URL from the VPS itself / 在 VPS 本机测试提交链接
  x cookies            Sync cookies now / 立即同步 cookies
  x cookies-menu       Show/change/sync cookie links / 查看、修改、同步 cookies
  x download-dir       Show/change download cache directory / 查看或修改下载缓存目录
  x chrome             Show Chrome submit setup / 显示 Chrome 提交配置
  x low-memory-help    Show swap and low-memory build commands / 显示 swap 和低内存编译命令
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
  if is_local_mode_selected; then
    public_current="no / 否"
    local_current="yes / 是"
  else
    public_current="yes / 是"
    local_current="no / 否"
  fi
  local_status="$(local_api_short_status)"
  cat <<EOF
Telegram Video Relay ${APP_VERSION} / Telegram 视频转发 ${APP_VERSION}

Upload mode overview / 上传模式概览

1) Public Telegram Bot API / 公网机器人 API
   Current / 当前正在用: ${public_current}
   Limit / 上传限制: about 50 MB / 约 50MB
   Compression / 压缩: AUTO_COMPRESS=true, large files are compressed / 大文件自动压缩
   Switch / 切换: x public

2) Local Bot API original quality / 本地 Bot API 原画质
   Current / 当前正在用: ${local_current}
   Status / 状态: ${local_status}
   Limit / 上传限制: about 2000 MB / 约 2000MB
   Compression / 压缩: AUTO_COMPRESS=false, keep original / 不压缩，保留原画质
   Switch / 切换: x local

Actions / 操作菜单

1) Start / 启动
2) Stop / Pause / 停止或暂停
3) Restart / 重启
4) Status / 状态
5) Doctor / 诊断
6) Logs / 日志
7) Switch upload mode / 切换上传模式
8) Update yt-dlp downloader / 更新 yt-dlp 下载器
9) Test cookies / 检测 X 和 YouTube cookies
10) Cookies sync / Cookies 同步和直链设置
11) Test submit X URL / 测试提交 X 链接
12) Test submit YouTube URL / 测试提交 YouTube 链接
13) iPhone Shortcut settings / iPhone 快捷指令配置
14) Chrome submit settings / Chrome 右键或书签提交配置
15) Download/cache directory / 下载缓存目录
16) Edit config / 编辑配置
17) Update / 更新
18) Reinstall / 重装
19) Uninstall service, keep files / 卸载服务但保留文件
20) Purge everything / 彻底删除
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
    7) run switch-mode ;;
    8) run ytdlp-update ;;
    9) run cookies-test ;;
    10) run cookies-menu ;;
    11) read -r -p "X URL: " test_url; run test-submit "${test_url}" ;;
    12) read -r -p "YouTube URL: " test_url; run test-submit "${test_url}" ;;
    13) run shortcut ;;
    14) run chrome ;;
    15) run download-dir ;;
    16) run env ;;
    17) run update ;;
    18) run reinstall ;;
    19) run uninstall ;;
    20) run purge ;;
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

backup_and_reset_dirty_checkout() {
  repo_dir="$1"
  backup_dir="/root/tg-video-relay-backups"
  dirty="$(git -C "${repo_dir}" status --porcelain 2>/dev/null || true)"
  [ -n "${dirty}" ] || return 0
  stamp="$(date +%Y%m%d%H%M%S)"
  mkdir -p "${backup_dir}"
  git -C "${repo_dir}" diff > "${backup_dir}/local-changes-${stamp}.patch" 2>/dev/null || true
  git -C "${repo_dir}" diff --cached > "${backup_dir}/local-staged-${stamp}.patch" 2>/dev/null || true
  git -C "${repo_dir}" status --porcelain > "${backup_dir}/local-status-${stamp}.txt" 2>/dev/null || true
  echo "Local Git changes found. Backed them up to / 发现本地 Git 改动，已备份到:"
  echo "  ${backup_dir}/local-changes-${stamp}.patch"
  echo "  ${backup_dir}/local-status-${stamp}.txt"
  echo "Resetting app code to match GitHub. / 正在把程序代码重置为 GitHub 版本。"
  git -C "${repo_dir}" reset --hard HEAD
}

install_control_wrapper() {
  [ -f "${APP_DIR}/control.sh" ] || return 0
  chmod 755 "${APP_DIR}/control.sh"
  cat > "${CONTROL_BIN}" <<EOF_CONTROL
#!/usr/bin/env bash
export APP_DIR="${APP_DIR}"
exec "${APP_DIR}/control.sh" "\$@"
EOF_CONTROL
  chmod 755 "${CONTROL_BIN}"
  cat > "${ALT_CONTROL_BIN}" <<EOF_CONTROL
#!/usr/bin/env bash
export APP_DIR="${APP_DIR}"
exec "${APP_DIR}/control.sh" "\$@"
EOF_CONTROL
  chmod 755 "${ALT_CONTROL_BIN}"
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
  if is_local_mode_selected; then
    public_current="no / 否"
    local_current="yes / 是"
  else
    public_current="yes / 是"
    local_current="no / 否"
  fi

  echo "== Upload mode overview / 上传模式概览 =="
  echo
  echo "1) Public Telegram Bot API / 公网机器人 API"
  echo "Available / 可用: yes / 是"
  echo "Current / 当前正在用: ${public_current}"
  echo "Upload limit / 上传限制: about 50 MB / 约 50MB"
  echo "Compression / 压缩: AUTO_COMPRESS=true, large files are compressed / 大文件自动压缩"
  echo "Use when / 适合: normal bot upload, most compatible / 普通机器人上传，兼容性最好"
  echo "Switch command / 切换命令: x public"
  echo

  echo "2) Local Bot API original quality / 本地 Bot API 原画质"
  echo "Current / 当前正在用: ${local_current}"
  printf 'API credentials saved / API ID 和 hash 已保存: '
  [ -f "${LOCAL_API_ENV}" ] && echo "yes / 是" || echo "no / 否"
  printf 'Binary installed / 程序已安装: '
  [ -x /usr/local/bin/telegram-bot-api ] && echo "yes / 是" || echo "no / 否"
  printf 'Service active / 服务运行中: '
  systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null && echo "yes / 是" || echo "no / 否"
  printf 'Port listening / 端口监听: '
  ss -lnt 2>/dev/null | grep -q ":${LOCAL_API_PORT} " && echo "yes / 是" || echo "no / 否"
  echo "Upload limit / 上传限制: about 2000 MB / 约 2000MB"
  echo "Compression / 压缩: AUTO_COMPRESS=false, keep original / 不压缩，保留原画质"
  echo "Use when / 适合: large videos and original quality / 大视频、原画质"
  echo "Switch command / 切换命令: x local"
  echo

  echo "== Current .env upload settings / 当前 .env 上传配置 =="
  printf 'BOT_API_BASE_URL=%s\n' "$(env_value BOT_API_BASE_URL)"
  printf 'BOT_API_USE_LOCAL_FILE_URI=%s\n' "$(env_value BOT_API_USE_LOCAL_FILE_URI)"
  printf 'DOWNLOAD_FORMAT=%s\n' "$(env_value DOWNLOAD_FORMAT)"
  printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
  printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
}

youtube_cookies_test() {
  need_root
  ensure_env_defaults
  url="${1:-}"
  if [ -z "${url}" ]; then
    url="https://www.youtube.com/watch?v=y3UWClkcvTA"
  fi

  cookie_path="$(env_value COOKIES_FILE_YOUTUBE)"
  if [ -z "${cookie_path}" ]; then
    cookie_path="$(env_value COOKIES_FILE)"
  fi

  echo "== YouTube cookies test / YouTube cookies 检测 =="
  echo "Test URL / 测试链接: ${url}"
  echo "Cookie file / Cookie 文件: ${cookie_path:-missing / 未设置}"
  echo

  if [ -z "${cookie_path}" ]; then
    echo "FAIL / 失败: COOKIES_FILE_YOUTUBE is not set in ${APP_DIR}/.env"
    echo "请在 .env 里设置: COOKIES_FILE_YOUTUBE=${APP_DIR}/cookies_youtube.txt"
    exit 1
  fi
  if [ ! -f "${cookie_path}" ]; then
    echo "FAIL / 失败: cookie file does not exist / 文件不存在"
    echo "Upload your YouTube cookies to / 把 YouTube cookies 上传到: ${cookie_path}"
    exit 1
  fi

  ls -lh "${cookie_path}"
  perms="$(stat -c '%a' "${cookie_path}" 2>/dev/null || true)"
  echo "Permission / 权限: ${perms:-unknown}"
  if [ "${perms}" != "600" ]; then
    echo "Tip / 建议: chmod 600 '${cookie_path}'"
  fi

  if grep -qi 'Netscape HTTP Cookie File' "${cookie_path}"; then
    echo "Format / 格式: Netscape cookies.txt OK / 正确"
  else
    echo "FAIL / 失败: this does not look like Netscape cookies.txt"
    echo "这不像 Netscape 格式 cookies.txt，可能是网页源码或 JSON。请用浏览器扩展导出 Netscape 格式。"
    exit 1
  fi

  youtube_cookie_count="$(grep -Ei '(^|[[:space:]])\.?(youtube|google)\.com[[:space:]]' "${cookie_path}" | wc -l | tr -d ' ')"
  echo "YouTube/Google cookie rows / YouTube 或 Google cookie 行数: ${youtube_cookie_count}"
  if [ "${youtube_cookie_count}" = "0" ]; then
    echo "FAIL / 失败: no youtube.com/google.com cookies found"
    echo "文件里没有 YouTube/Google cookies，可能导错网站或导出失败。"
    exit 1
  fi

  echo
  echo "Running yt-dlp format probe / 正在用 yt-dlp 测试列出格式..."
  echo "If this shows 1080p/1440p/2160p formats, cookies are at least readable."
  echo "如果这里能列出 1080p/1440p/2160p，说明 cookies 至少能被 yt-dlp 读取。"
  echo
  "${APP_DIR}/.venv/bin/python" -m yt_dlp \
    --cookies "${cookie_path}" \
    --no-playlist \
    --skip-download \
    -F "${url}"
}

cookie_file_status() {
  label="$1"
  path="$2"
  domain_pattern="$3"

  echo "== ${label} cookies =="
  echo "File / 文件: ${path:-missing / 未设置}"
  if [ -z "${path}" ]; then
    echo "Status / 状态: path missing / 路径未设置"
    echo
    return
  fi
  if [ ! -f "${path}" ]; then
    echo "Status / 状态: file missing / 文件不存在"
    echo
    return
  fi
  ls -lh "${path}"
  perms="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  echo "Permission / 权限: ${perms:-unknown}"
  if grep -qi 'Netscape HTTP Cookie File' "${path}"; then
    echo "Format / 格式: Netscape OK / 正确"
  else
    echo "Format / 格式: maybe invalid / 可能不是 Netscape cookies.txt"
  fi
  rows="$(grep -Ei "${domain_pattern}" "${path}" | wc -l | tr -d ' ')"
  echo "Matched rows / 匹配行数: ${rows}"
  echo
}

test_all_cookies() {
  need_root
  ensure_env_defaults
  cookie_file_status "X" "$(env_value COOKIES_FILE_X)" '(^|[[:space:]])\.?(x|twitter)\.com[[:space:]]'
  cookie_file_status "YouTube" "$(env_value COOKIES_FILE_YOUTUBE)" '(^|[[:space:]])\.?(youtube|google)\.com[[:space:]]'
}

cookie_sync_config() {
  need_root
  ensure_env_defaults
  env_file="${APP_DIR}/.env"
  [ -f "${env_file}" ] || { echo "${env_file} not found."; exit 1; }

  echo "Current cookie status / 当前 cookies 状态:"
  echo
  test_all_cookies
  echo "Current cookie sync links / 当前 cookies 同步直链:"
  echo "  COOKIES_FILE_X=$(env_value COOKIES_FILE_X)"
  echo "  COOKIE_SYNC_URL_X=$(env_value COOKIE_SYNC_URL_X)"
  echo "  COOKIES_FILE_YOUTUBE=$(env_value COOKIES_FILE_YOUTUBE)"
  echo "  COOKIE_SYNC_URL_YOUTUBE=$(env_value COOKIE_SYNC_URL_YOUTUBE)"
  echo "  COOKIE_SYNC_INTERVAL_MINUTES=$(env_value COOKIE_SYNC_INTERVAL_MINUTES)"
  echo
  echo "Google Drive share links like /file/d/.../view are OK; the program converts them automatically."
  echo "Google Drive 分享页链接可以直接填，程序会自动转成下载链接。"
  echo

  read -r -p "Change X cookies sync link? [y/N] / 是否修改 X cookies 直链？[y/N]: " change_x
  if [[ "${change_x}" =~ ^[Yy]$ ]]; then
    read -r -p "New X cookies sync link, empty to clear / 新 X cookies 直链，留空为删除: " new_x
    set_env_value "${env_file}" COOKIE_SYNC_URL_X "${new_x}"
  fi

  read -r -p "Change YouTube cookies sync link? [y/N] / 是否修改 YouTube cookies 直链？[y/N]: " change_youtube
  if [[ "${change_youtube}" =~ ^[Yy]$ ]]; then
    read -r -p "New YouTube cookies sync link, empty to clear / 新 YouTube cookies 直链，留空为删除: " new_youtube
    set_env_value "${env_file}" COOKIE_SYNC_URL_YOUTUBE "${new_youtube}"
  fi

  current_interval="$(env_value COOKIE_SYNC_INTERVAL_MINUTES)"
  read -r -p "Change sync interval minutes? [${current_interval:-360}, Enter keep] / 修改同步间隔分钟？[回车保留]: " new_interval
  [ -n "${new_interval}" ] && set_env_value "${env_file}" COOKIE_SYNC_INTERVAL_MINUTES "${new_interval}"

  echo
  read -r -p "Sync cookies now? [Y/n] / 现在同步 cookies？[Y/n]: " sync_now
  if [[ ! "${sync_now}" =~ ^[Nn]$ ]]; then
    cd "${APP_DIR}"
    "${APP_DIR}/.venv/bin/python" -m tg_video_relay_bot.cookie_sync || true
  fi

  echo
  echo "Updated status / 更新后状态:"
  echo
  test_all_cookies
  read -r -p "Press Enter to return menu / 按回车返回菜单: " _
  menu
}

download_dir_config() {
  need_root
  ensure_env_defaults
  env_file="${APP_DIR}/.env"
  [ -f "${env_file}" ] || { echo "${env_file} not found."; exit 1; }

  current_dir="$(env_value DOWNLOAD_DIR)"
  [ -n "${current_dir}" ] || current_dir="${APP_DIR}/downloads"

  echo "Download/cache directory / 下载缓存目录"
  echo "Current / 当前: ${current_dir}"
  if [ -d "${current_dir}" ]; then
    echo "Exists / 已存在: yes / 是"
    du -sh "${current_dir}" 2>/dev/null || true
  else
    echo "Exists / 已存在: no / 否"
  fi
  echo
  echo "This is where temporary downloaded videos are stored before upload."
  echo "这里是视频下载后、上传前的临时缓存目录。任务结束后会按配置清理。"
  echo
  read -r -p "Change download/cache directory? [y/N] / 是否修改下载缓存目录？[y/N]: " change_dir
  if [[ ! "${change_dir}" =~ ^[Yy]$ ]]; then
    return
  fi

  read -r -p "New directory / 新目录: " new_dir
  if [ -z "${new_dir}" ]; then
    echo "Empty path, cancelled. / 路径为空，已取消。"
    return
  fi

  mkdir -p "${new_dir}"
  set_env_value "${env_file}" DOWNLOAD_DIR "${new_dir}"
  systemctl restart "${APP_NAME}" 2>/dev/null || true
  echo "Updated DOWNLOAD_DIR=${new_dir}"
  echo "已更新下载缓存目录并重启服务。"
}

switch_upload_mode() {
  need_root
  ensure_env_defaults
  echo "Current mode / 当前模式: $(current_upload_mode_label)"
  echo
  echo "1) Public Bot API compatibility / 公网 Bot API 兼容模式，约 50MB，大文件会压缩"
  echo "2) Local Bot API original quality / 本地 Bot API 原画质模式，约 2000MB，不压缩"
  echo "0) Back / 返回"
  echo
  read -r -p "Choose mode / 选择模式: " mode_choice
  case "${mode_choice}" in
    1)
      bash "${APP_DIR}/install_local_bot_api.sh" public
      ;;
    2)
      if ! systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null; then
        echo "Local Bot API is not running. / 本地 Bot API 没有运行。"
        read -r -p "Install/configure it now? [y/N] / 现在安装或配置？[y/N]: " install_local
        [[ "${install_local}" =~ ^[Yy]$ ]] || { echo "Cancelled. / 已取消。"; return; }
        bash "${APP_DIR}/install_local_bot_api.sh" install
      fi
      bash "${APP_DIR}/install_local_bot_api.sh" switch
      set_env_value "${APP_DIR}/.env" MAX_UPLOAD_MB "1900"
      set_env_value "${APP_DIR}/.env" AUTO_COMPRESS "false"
      ;;
    0|"")
      return
      ;;
    *)
      echo "Invalid choice. / 选择无效。"
      return 1
      ;;
  esac
  systemctl restart "${APP_NAME}" 2>/dev/null || true
  echo "Done. / 完成。"
}

install_js_runtime() {
  need_root
  if command -v deno >/dev/null 2>&1; then
    echo "Deno is already installed. / Deno 已安装。"
    deno --version
    return
  fi

  echo "Installing Deno for yt-dlp YouTube extraction."
  echo "正在安装 Deno，用于 yt-dlp 解析 YouTube。"
  apt-get update
  apt-get install -y unzip curl ca-certificates
  tmp_dir="$(mktemp -d)"
  if ! curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip" -o "${tmp_dir}/deno.zip" \
    || ! unzip -o "${tmp_dir}/deno.zip" -d "${tmp_dir}" \
    || ! install -m 755 "${tmp_dir}/deno" /usr/local/bin/deno; then
    rm -rf "${tmp_dir}"
    echo "Deno install failed. / Deno 安装失败。"
    echo "You can try again later / 可以稍后重试:"
    echo "  x js-runtime-install"
    exit 1
  fi
  rm -rf "${tmp_dir}"
  deno --version
  echo
  echo "Done. Run YouTube test again / 完成，请重新测试："
  echo "  x youtube-cookies-test 'https://www.youtube.com/watch?v=y3UWClkcvTA'"
}

low_memory_help() {
  cat <<'EOF'
Low-memory VPS help / 低内存 VPS 帮助

Manual Deno install / 手动安装 Deno:
  x js-runtime-install

Local Bot API:
  telegram-bot-api is compiled from source and can use a lot of RAM.
  telegram-bot-api 需要源码编译，低内存 VPS 容易爆内存。
  The installer already uses low-memory mode by default: BUILD_JOBS=1.
  安装器默认已经使用低内存模式: BUILD_JOBS=1。
  It does not create swap unless ENABLE_SWAP=true is set.
  默认不会创建虚拟内存，除非你设置 ENABLE_SWAP=true。

Normal install / 正常安装:
  x local-api-install

Retry low-memory install / 重新低内存安装:
  BUILD_JOBS=1 x local-api-install

Retry with temporary swap enabled / 明确启用 swap 后重试:
  ENABLE_SWAP=true BUILD_JOBS=1 x local-api-install

Background build / 后台编译:
  BUILD_JOBS=1 x local-api-install-bg
  x local-api-install-log
EOF
}

set_1080p_original_defaults() {
  need_root
  ensure_env_defaults
  env_file="${APP_DIR}/.env"
  [ -f "${env_file}" ] || { echo "${env_file} not found."; exit 1; }

  set_env_value "${env_file}" DOWNLOAD_FORMAT "${DEFAULT_DOWNLOAD_FORMAT}"
  set_env_value "${env_file}" MERGE_OUTPUT_FORMAT "mp4"
  set_env_value "${env_file}" UPLOAD_MODE "video"
  set_env_value "${env_file}" YOUTUBE_PLAYER_CLIENTS "web,web_safari,ios,android"

  if systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null; then
    set_env_value "${env_file}" MAX_UPLOAD_MB "1900"
    set_env_value "${env_file}" AUTO_COMPRESS "false"
    bash "${APP_DIR}/install_local_bot_api.sh" switch
    echo
    echo "Done. Downloads will prefer the highest available quality and upload without compression."
    echo "完成。下载会优先最高可用画质，并使用不压缩上传。"
  else
    echo "Saved highest-quality DOWNLOAD_FORMAT, but Local Bot API is not active."
    echo "已保存最高可用下载格式，但本地 Bot API 还没运行。"
    echo
    echo "No-compress large uploads need Local Bot API. Run:"
    echo "不压缩上传大视频需要本地 Bot API，请执行："
    echo "  x local-api-install"
    echo "  x local"
    echo "  x 1080p"
    systemctl restart "${APP_NAME}" 2>/dev/null || true
  fi
}

switch_original_quality() {
  need_root
  ensure_env_defaults
  if ! systemctl is-active --quiet "${LOCAL_API_NAME}" 2>/dev/null; then
    echo "Local Bot API is not active, so original-quality large uploads are not ready."
    echo "本地 Bot API 没有运行，所以还不能原画质上传大文件。"
    echo
    echo "Run / 请执行："
    echo "  x local-api-install"
    echo "  x original"
    exit 1
  fi
  set_1080p_original_defaults
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
  grep -q '^DOWNLOAD_DIR=' "${env_file}" || printf 'DOWNLOAD_DIR=%s/downloads\n' "${APP_DIR}" >> "${env_file}"
  grep -q '^MAX_UPLOAD_MB=' "${env_file}" || printf 'MAX_UPLOAD_MB=49\n' >> "${env_file}"
  if grep -Fqx "DOWNLOAD_FORMAT=${OLD_1080P_DOWNLOAD_FORMAT}" "${env_file}"; then
    set_env_value "${env_file}" DOWNLOAD_FORMAT "${DEFAULT_DOWNLOAD_FORMAT}"
  fi
  grep -q '^DOWNLOAD_FORMAT=' "${env_file}" || printf 'DOWNLOAD_FORMAT=%s\n' "${DEFAULT_DOWNLOAD_FORMAT}" >> "${env_file}"
  grep -q '^AUTO_COMPRESS=' "${env_file}" || printf 'AUTO_COMPRESS=true\n' >> "${env_file}"
  grep -q '^COMPRESS_AUDIO_KBPS=' "${env_file}" || printf 'COMPRESS_AUDIO_KBPS=96\n' >> "${env_file}"
  grep -q '^COMPRESS_MIN_VIDEO_KBPS=' "${env_file}" || printf 'COMPRESS_MIN_VIDEO_KBPS=60\n' >> "${env_file}"
  grep -q '^UPLOAD_RETRIES=' "${env_file}" || printf 'UPLOAD_RETRIES=3\n' >> "${env_file}"
  grep -q '^YTDLP_FORCE_IPV4=' "${env_file}" || printf 'YTDLP_FORCE_IPV4=true\n' >> "${env_file}"
  grep -q '^YTDLP_HTTP_CHUNK_SIZE=' "${env_file}" || printf 'YTDLP_HTTP_CHUNK_SIZE=10M\n' >> "${env_file}"
  grep -q '^YOUTUBE_PLAYER_CLIENTS=' "${env_file}" || printf 'YOUTUBE_PLAYER_CLIENTS=web,web_safari,ios,android\n' >> "${env_file}"
  grep -q '^COOKIES_FILE_X=' "${env_file}" || printf 'COOKIES_FILE_X=%s/cookies_x.txt\n' "${APP_DIR}" >> "${env_file}"
  grep -q '^COOKIES_FILE_YOUTUBE=' "${env_file}" || printf 'COOKIES_FILE_YOUTUBE=%s/cookies_youtube.txt\n' "${APP_DIR}" >> "${env_file}"
  grep -q '^COOKIE_SYNC_URL=' "${env_file}" || printf 'COOKIE_SYNC_URL=\n' >> "${env_file}"
  grep -q '^COOKIE_SYNC_URL_X=' "${env_file}" || printf 'COOKIE_SYNC_URL_X=\n' >> "${env_file}"
  grep -q '^COOKIE_SYNC_URL_YOUTUBE=' "${env_file}" || printf 'COOKIE_SYNC_URL_YOUTUBE=\n' >> "${env_file}"
  grep -q '^COOKIE_SYNC_INTERVAL_MINUTES=' "${env_file}" || printf 'COOKIE_SYNC_INTERVAL_MINUTES=360\n' >> "${env_file}"
  if [ "$(env_value COOKIES_FILE)" = "${APP_DIR}/cookies.txt" ]; then
    set_env_value "${env_file}" COOKIES_FILE ""
  fi
  grep -q '^TELEGRAM_RESOLUTION_MENU=' "${env_file}" || printf 'TELEGRAM_RESOLUTION_MENU=true\n' >> "${env_file}"
  grep -q '^TELEGRAM_RESOLUTION_AUTO_SECONDS=' "${env_file}" || printf 'TELEGRAM_RESOLUTION_AUTO_SECONDS=3\n' >> "${env_file}"
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
    switch-mode|upload-mode|mode-switch)
      switch_upload_mode
      ;;
    1080p|youtube-1080p|quality-1080p)
      set_1080p_original_defaults
      ;;
    original|original-quality|no-compress)
      switch_original_quality
      ;;
    doctor)
      need_root
      ensure_env_defaults
      port="$(env_value SUBMIT_API_PORT)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      secret="$(env_value SUBMIT_API_SECRET)"
      [ -n "${port}" ] || port="8787"
      echo "== Version / 版本 =="
      echo "APP_VERSION=${APP_VERSION}"
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
      printf 'DOWNLOAD_DIR=%s\n' "$(env_value DOWNLOAD_DIR)"
      printf 'DOWNLOAD_FORMAT=%s\n' "$(env_value DOWNLOAD_FORMAT)"
      printf 'MAX_UPLOAD_MB=%s\n' "$(env_value MAX_UPLOAD_MB)"
      printf 'AUTO_COMPRESS=%s\n' "$(env_value AUTO_COMPRESS)"
      printf 'UPLOAD_TIMEOUT=%s\n' "$(env_value UPLOAD_TIMEOUT)"
      printf 'UPLOAD_RETRIES=%s\n' "$(env_value UPLOAD_RETRIES)"
      printf 'YTDLP_FORCE_IPV4=%s\n' "$(env_value YTDLP_FORCE_IPV4)"
      printf 'YTDLP_HTTP_CHUNK_SIZE=%s\n' "$(env_value YTDLP_HTTP_CHUNK_SIZE)"
      printf 'YOUTUBE_PLAYER_CLIENTS=%s\n' "$(env_value YOUTUBE_PLAYER_CLIENTS)"
      printf 'COOKIES_FILE_X=%s\n' "$(env_value COOKIES_FILE_X)"
      printf 'COOKIES_FILE_YOUTUBE=%s\n' "$(env_value COOKIES_FILE_YOUTUBE)"
      printf 'COOKIES_FILE=%s\n' "$(env_value COOKIES_FILE)"
      [ -n "$(env_value COOKIE_SYNC_URL_X)" ] && echo "COOKIE_SYNC_URL_X=set / 已设置" || echo "COOKIE_SYNC_URL_X=empty / 未设置"
      [ -n "$(env_value COOKIE_SYNC_URL_YOUTUBE)" ] && echo "COOKIE_SYNC_URL_YOUTUBE=set / 已设置" || echo "COOKIE_SYNC_URL_YOUTUBE=empty / 未设置"
      printf 'COOKIE_SYNC_INTERVAL_MINUTES=%s\n' "$(env_value COOKIE_SYNC_INTERVAL_MINUTES)"
      printf 'TELEGRAM_RESOLUTION_MENU=%s\n' "$(env_value TELEGRAM_RESOLUTION_MENU)"
      if command -v deno >/dev/null 2>&1; then
        printf 'DENO=%s\n' "$(command -v deno)"
        deno --version | head -n 1
      else
        echo "DENO=missing / 缺失，建议执行: x js-runtime-install"
      fi
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
    ytdlp-update|yt-dlp-update|update-ytdlp)
      need_root
      "${APP_DIR}/.venv/bin/python" -m pip install --upgrade yt-dlp
      "${APP_DIR}/.venv/bin/python" -m yt_dlp --version
      systemctl restart "${APP_NAME}"
      echo "yt-dlp updated and bot restarted. / yt-dlp 已更新并已重启机器人。"
      ;;
    ytdlp-version|yt-dlp-version)
      "${APP_DIR}/.venv/bin/python" -m yt_dlp --version
      ;;
    js-runtime-install|js-install|deno-install)
      install_js_runtime
      ;;
    low-memory-help|swap-help|memory-help)
      low_memory_help
      ;;
    youtube-cookies-test|youtube-cookie-test|ytcookie|yt-cookies)
      youtube_cookies_test "${2:-}"
      ;;
    cookies-test|cookie-test|test-cookies)
      test_all_cookies
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
      echo "  DOWNLOAD_FORMAT=${DEFAULT_DOWNLOAD_FORMAT}"
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
    logs-recent|recent-logs)
      lines="${2:-120}"
      journalctl -u "${APP_NAME}" -n "${lines}" --no-pager
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
    cookies-menu|cookies-config|cookie-config|sync-cookies-config)
      cookie_sync_config
      ;;
    download-dir|download-cache|cache-dir)
      download_dir_config
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
    chrome|browser-submit|chrome-submit|chrome-extension)
      need_root
      ensure_env_defaults
      port="$(env_value SUBMIT_API_PORT)"
      secret="$(env_value SUBMIT_API_SECRET)"
      enabled="$(env_value SUBMIT_API_ENABLED)"
      host_hint="$(hostname -I 2>/dev/null | awk '{print $1}')"
      [ -n "${port}" ] || port="8787"
      [ -n "${host_hint}" ] || host_hint="YOUR_VPS_IP_OR_DOMAIN"
      default_submit_url="http://${host_hint}:${port}/submit"
      submit_url="${2:-}"
      if [ -z "${submit_url}" ]; then
        echo "Chrome right-click extension / Chrome 右键提交扩展"
        echo
        echo "Enter your VPS submit URL. Use IP, not domain, if your domain has HTTPS problems."
        echo "请输入 VPS 提交地址。域名 HTTPS 有问题就直接用 IP。"
        echo "Example / 示例:"
        echo "  http://143.20.156.100:8787/submit"
        read -r -p "Submit URL [${default_submit_url}]: " submit_url
      fi
      [ -n "${submit_url}" ] || submit_url="${default_submit_url}"
      case "${submit_url}" in
        http://*|https://*) ;;
        *) submit_url="http://${submit_url}" ;;
      esac
      case "${submit_url}" in
        */submit) ;;
        */) submit_url="${submit_url}submit" ;;
        *) submit_url="${submit_url}/submit" ;;
      esac
      case "${submit_url}" in
        https://*:8787/*) submit_url="http://${submit_url#https://}" ;;
      esac
      export SUBMIT_URL_FOR_CHROME="${submit_url}"
      export SUBMIT_SECRET_FOR_CHROME="${secret}"
      host_permission="$(python3 -c 'import os, urllib.parse; u=urllib.parse.urlsplit(os.environ["SUBMIT_URL_FOR_CHROME"]); print(f"{u.scheme}://{u.netloc}/*")')"
      submit_url_js="$(python3 -c 'import json, os; print(json.dumps(os.environ["SUBMIT_URL_FOR_CHROME"]))')"
      secret_js="$(python3 -c 'import json, os; print(json.dumps(os.environ["SUBMIT_SECRET_FOR_CHROME"]))')"
      extension_dir="${APP_DIR}/chrome-tg-relay-extension"
      extension_zip="${APP_DIR}/chrome-tg-relay-extension.zip"
      rm -rf "${extension_dir}" "${extension_zip}"
      export CHROME_EXTENSION_DIR="${extension_dir}"
      export CHROME_EXTENSION_ZIP="${extension_zip}"
      export CHROME_HOST_PERMISSION="${host_permission}"
      python3 - <<'PY_CHROME_EXTENSION'
import json
import os
import pathlib
import zipfile

extension_dir = pathlib.Path(os.environ["CHROME_EXTENSION_DIR"])
extension_zip = pathlib.Path(os.environ["CHROME_EXTENSION_ZIP"])
submit_url = os.environ["SUBMIT_URL_FOR_CHROME"]
secret = os.environ["SUBMIT_SECRET_FOR_CHROME"]
host_permission = os.environ["CHROME_HOST_PERMISSION"]

extension_dir.mkdir(parents=True, exist_ok=True)
manifest = {
    "manifest_version": 3,
    "name": "TG Video Relay Sender",
    "version": "1.1.1",
    "description": "Right-click a page or link and send it to Telegram Video Relay.",
    "permissions": ["contextMenus", "activeTab", "tabs", "storage", "clipboardRead", "scripting"],
    "host_permissions": [host_permission],
    "background": {"service_worker": "background.js"},
    "action": {"default_title": "Send current page to TG Relay"},
    "content_scripts": [
        {
            "matches": [
                "https://x.com/*",
                "https://twitter.com/*",
                "https://www.youtube.com/*",
                "https://youtu.be/*"
            ],
            "js": ["content.js"],
            "run_at": "document_idle",
            "all_frames": False,
        }
    ],
}
(extension_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

background = f'''const SUBMIT_URL = {json.dumps(submit_url)};
const SECRET = {json.dumps(secret)};

function submitEndpoint() {{
  try {{
    const endpoint = new URL(SUBMIT_URL);
    if (endpoint.protocol === "https:" && endpoint.port === "8787") {{
      endpoint.protocol = "http:";
    }}
    return endpoint;
  }} catch {{
    return new URL(SUBMIT_URL);
  }}
}}

function mark(text) {{
  chrome.action.setBadgeText({{ text }});
  chrome.action.setBadgeBackgroundColor({{ color: text === "OK" ? "#16a34a" : "#dc2626" }});
  setTimeout(() => chrome.action.setBadgeText({{ text: "" }}), 3500);
}}

function cleanUrl(url) {{
  if (!url) return "";
  try {{
    const parsed = new URL(url);
    const statusMatch = parsed.pathname.match(/^\\/([^/]+)\\/status\\/(\\d+)/);
    if ((parsed.hostname === "x.com" || parsed.hostname === "twitter.com") && statusMatch) {{
      return parsed.origin + "/" + statusMatch[1] + "/status/" + statusMatch[2];
    }}
    return parsed.href;
  }} catch {{
    return String(url || "");
  }}
}}

function isBadFallbackUrl(url) {{
  try {{
    const parsed = new URL(url);
    return (parsed.hostname === "x.com" || parsed.hostname === "twitter.com") &&
      (parsed.pathname === "/" || parsed.pathname === "/home");
  }} catch {{
    return false;
  }}
}}

async function getContentScriptUrl(tab) {{
  let messageUrl = "";
  try {{
    if (tab && tab.id) {{
      const response = await chrome.tabs.sendMessage(tab.id, {{ type: "get-submit-url" }});
      messageUrl = response && response.url ? response.url : "";
    }}
  }} catch (error) {{
    messageUrl = "";
  }}
  if (messageUrl && !isBadFallbackUrl(messageUrl)) return messageUrl;
  try {{
    const stored = await chrome.storage.session.get(["tgRelayLastRightClickUrl", "tgRelayLastRightClickAt"]);
    const ageMs = Date.now() - Number(stored.tgRelayLastRightClickAt || 0);
    if (stored.tgRelayLastRightClickUrl && ageMs < 30000 && !isBadFallbackUrl(stored.tgRelayLastRightClickUrl)) {{
      return stored.tgRelayLastRightClickUrl;
    }}
  }} catch (error) {{}}
  return "";
}}

async function getClipboardOrPromptUrl(tab) {{
  if (!tab || !tab.id) return "";
  try {{
    const results = await chrome.scripting.executeScript({{
      target: {{ tabId: tab.id }},
      func: async () => {{
        function normalize(raw) {{
          if (!raw) return "";
          try {{
            const parsed = new URL(raw, location.href);
            const statusMatch = parsed.pathname.match(/^\\/([^/]+)\\/status\\/(\\d+)/);
            if ((parsed.hostname === "x.com" || parsed.hostname === "twitter.com") && statusMatch) {{
              return parsed.origin + "/" + statusMatch[1] + "/status/" + statusMatch[2];
            }}
            return parsed.href;
          }} catch {{
            return String(raw || "");
          }}
        }}
        function supported(url) {{
          return /^https?:\\/\\/(x\\.com|twitter\\.com)\\/[^/]+\\/status\\/\\d+/.test(url)
            || /^https?:\\/\\/www\\.youtube\\.com\\/watch\\?/.test(url)
            || /^https?:\\/\\/youtu\\.be\\//.test(url)
            || /^https?:\\/\\/(www\\.)?tiktok\\.com\\//.test(url)
            || /^https?:\\/\\/v\\.douyin\\.com\\//.test(url);
        }}
        try {{
          const text = (await navigator.clipboard.readText()).trim();
          const url = normalize(text);
          if (supported(url)) return url;
        }} catch (error) {{}}
        const pasted = window.prompt("没有读到剪贴板里的真实链接，请粘贴 X/YouTube/TikTok/Douyin 链接：", "");
        const url = normalize(pasted || "");
        return supported(url) ? url : "";
      }}
    }});
    return results && results[0] && results[0].result ? results[0].result : "";
  }} catch (error) {{
    return "";
  }}
}}

async function submitUrl(rawUrl) {{
  const targetUrl = cleanUrl(rawUrl);
  if (!targetUrl || targetUrl.startsWith("chrome://") || targetUrl.startsWith("edge://") || isBadFallbackUrl(targetUrl)) {{
    mark("ERR");
    console.warn("TG Relay: no valid page/link URL found");
    return;
  }}
  try {{
    const submit = submitEndpoint();
    submit.searchParams.set("secret", SECRET);
    submit.searchParams.set("url", targetUrl);
    const response = await fetch(submit.href, {{
      method: "GET",
      cache: "no-store",
      credentials: "omit"
    }});
    if (!response.ok) {{
      const text = await response.text().catch(() => "");
      throw new Error(text || response.statusText || String(response.status));
    }}
    mark("OK");
    console.log("TG Relay submitted:", targetUrl);
  }} catch (error) {{
    mark("ERR");
    console.error("TG Relay failed:", error && error.message ? error.message : error);
  }}
}}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {{
  if (message && message.type === "submit-url" && message.url) {{
    submitUrl(message.url);
    sendResponse({{ ok: true }});
    return true;
  }}
  return false;
}});

chrome.runtime.onInstalled.addListener(() => {{
  chrome.contextMenus.removeAll(() => {{
    chrome.contextMenus.create({{
      id: "send-to-tg-relay",
      title: "发送到 TG Relay 下载最高画质",
      contexts: ["page", "link", "video", "image", "audio", "selection"]
    }});
  }});
}});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {{
  const pageCardUrl = await getContentScriptUrl(tab);
  const clipboardOrPromptUrl = info.linkUrl ? "" : await getClipboardOrPromptUrl(tab);
  const targetUrl = info.linkUrl || clipboardOrPromptUrl || pageCardUrl || info.srcUrl || "";
  submitUrl(targetUrl);
}});

chrome.action.onClicked.addListener((tab) => {{
  submitUrl(tab && tab.url);
}});
'''
(extension_dir / "background.js").write_text(background, encoding="utf-8")

content = '''let lastRightClickUrl = null;

function normalizeUrl(raw) {
  if (!raw) return "";
  try {
    const parsed = new URL(raw, location.href);
    const statusMatch = parsed.pathname.match(/^\\/([^/]+)\\/status\\/(\\d+)/);
    if ((parsed.hostname === "x.com" || parsed.hostname === "twitter.com") && statusMatch) {
      return parsed.origin + "/" + statusMatch[1] + "/status/" + statusMatch[2];
    }
    return parsed.href;
  } catch {
    return String(raw || "");
  }
}

function findStatusUrl(root) {
  if (!root) return null;
  const links = [];
  if (root.matches && root.matches("a[href]")) links.push(root);
  if (root.querySelectorAll) links.push(...Array.from(root.querySelectorAll("a[href]")));
  const statusUrl = links
    .map((anchor) => anchor.href)
    .find((href) => /^https?:\\/\\/(x\\.com|twitter\\.com)\\/[^/]+\\/status\\/\\d+/.test(href));
  return statusUrl ? normalizeUrl(statusUrl) : null;
}

function findUrlFromTarget(target) {
  const element = target instanceof Element ? target : target && target.parentElement;
  if (!element) return null;

  const directLink = element.closest("a[href]");
  if (directLink && directLink.href && /\\/status\\/\\d+/.test(directLink.href)) {
    return normalizeUrl(directLink.href);
  }

  const articleUrl = findStatusUrl(element.closest("article"));
  if (articleUrl) return articleUrl;

  const tweetUrl = findStatusUrl(element.closest('[data-testid="tweet"]'));
  if (tweetUrl) return tweetUrl;

  if (document.elementsFromPoint) {
    const pointElements = document.elementsFromPoint(window.tgRelayLastClientX || 0, window.tgRelayLastClientY || 0);
    for (const pointElement of pointElements) {
      const pointArticleUrl = findStatusUrl(pointElement.closest && pointElement.closest("article"));
      if (pointArticleUrl) return pointArticleUrl;
      const pointTweetUrl = findStatusUrl(pointElement.closest && pointElement.closest('[data-testid="tweet"]'));
      if (pointTweetUrl) return pointTweetUrl;
    }
  }

  let node = element;
  for (let i = 0; node && i < 14; i += 1, node = node.parentElement) {
    const nearbyUrl = findStatusUrl(node);
    if (nearbyUrl) return nearbyUrl;
  }

  if (/^https:\\/\\/(www\\.)?youtube\\.com\\/watch/.test(location.href) || /^https:\\/\\/youtu\\.be\\//.test(location.href)) {
    return location.href;
  }

  return null;
}

function rememberEvent(event) {
  window.tgRelayLastClientX = event.clientX;
  window.tgRelayLastClientY = event.clientY;
  lastRightClickUrl = findUrlFromTarget(event.target) || "";
  try {
    chrome.storage.session.set({
      tgRelayLastRightClickUrl: lastRightClickUrl,
      tgRelayLastRightClickAt: Date.now()
    });
  } catch {}
}

document.addEventListener("pointerdown", (event) => {
  if (event.button === 2) rememberEvent(event);
}, true);

document.addEventListener("contextmenu", rememberEvent, true);

function looksLikeCopyLinkClick(event) {
  const element = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
  if (!element) return false;
  const text = (element.innerText || element.textContent || "").trim();
  const menuItem = element.closest('[role="menuitem"], [data-testid]');
  const menuText = menuItem ? (menuItem.innerText || menuItem.textContent || "").trim() : "";
  return /复制链接|复制連結|Copy link|Copy Link/.test(text + " " + menuText);
}

function isSupportedShareUrl(url) {
  return /^https?:\\/\\/(x\\.com|twitter\\.com)\\/[^/]+\\/status\\/\\d+/.test(url)
    || /^https?:\\/\\/www\\.youtube\\.com\\/watch\\?/.test(url)
    || /^https?:\\/\\/youtu\\.be\\//.test(url);
}

async function maybeSubmitCopiedLink() {
  try {
    const text = (await navigator.clipboard.readText()).trim();
    const url = normalizeUrl(text);
    if (!isSupportedShareUrl(url)) return;
    const ok = window.confirm("发送到 TG Relay 下载最高画质？\\n\\n" + url);
    if (!ok) return;
    chrome.runtime.sendMessage({ type: "submit-url", url });
  } catch (error) {
    console.warn("TG Relay: cannot read copied link", error);
  }
}

async function getClipboardShareUrl() {
  try {
    const text = (await navigator.clipboard.readText()).trim();
    const url = normalizeUrl(text);
    return isSupportedShareUrl(url) ? url : "";
  } catch (error) {
    console.warn("TG Relay: cannot read clipboard", error);
    return "";
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "get-submit-url") {
    getClipboardShareUrl().then((clipboardUrl) => {
      sendResponse({ url: clipboardUrl || lastRightClickUrl || "" });
    });
    return true;
  }
  if (message && message.type === "get-right-click-url") {
    sendResponse({ url: lastRightClickUrl });
  }
  return true;
});
'''
(extension_dir / "content.js").write_text(content, encoding="utf-8")

readme = """TG Video Relay Sender

1. Open chrome://extensions
2. Enable Developer mode
3. Load unpacked: select this chrome-tg-relay-extension folder
4. Right-click an X/YouTube page or link and choose: 发送到 TG Relay 下载最高画质

Tip: On X, the most reliable method is: click the X share button, click Copy link / 复制链接, then right-click and choose 发送到 TG Relay 下载最高画质. The extension reads the copied real /status/ URL first.
"""
(extension_dir / "README.txt").write_text(readme, encoding="utf-8")

if extension_zip.exists():
    extension_zip.unlink()
with zipfile.ZipFile(extension_zip, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in extension_dir.rglob("*"):
        if path.is_file():
            archive.write(path, pathlib.Path(extension_dir.name) / path.relative_to(extension_dir))
PY_CHROME_EXTENSION
      chmod 600 "${extension_dir}/background.js" "${extension_dir}/content.js" "${extension_zip}" 2>/dev/null || true
      echo "Chrome right-click extension generated / Chrome 右键扩展已生成"
      echo "Submit API enabled / 提交接口启用: ${enabled:-unknown}"
      echo
      echo "  ${submit_url}"
      echo
      echo "Extension folder / 扩展目录:"
      echo "  ${extension_dir}"
      echo "Extension zip / 扩展压缩包:"
      echo "  ${extension_zip}"
      echo
      echo "Chrome setup / Chrome 设置:"
      echo "  1. Download the zip to your Windows PC and unzip it."
      echo "     把 zip 下载到电脑并解压。"
      echo "  2. Open chrome://extensions and enable Developer mode."
      echo "     打开 chrome://extensions，开启开发者模式。"
      echo "  3. Click Load unpacked and select the unzipped chrome-tg-relay-extension folder."
      echo "     点“加载已解压的扩展程序”，选择解压后的 chrome-tg-relay-extension 文件夹。"
      echo "  4. Right-click an X/YouTube page or link, choose: 发送到 TG Relay 下载最高画质"
      echo "     以后在 X/YouTube 页面或链接上右键，点“发送到 TG Relay 下载最高画质”。"
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
      backup_and_reset_dirty_checkout "${APP_DIR}"
      git -C "${APP_DIR}" fetch origin "${BRANCH}"
      git -C "${APP_DIR}" checkout "${BRANCH}"
      git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
      "${APP_DIR}/.venv/bin/python" -m pip install --upgrade -r "${APP_DIR}/requirements.txt"
      "${APP_DIR}/.venv/bin/python" -m pip install --upgrade yt-dlp
      ensure_env_defaults
      install_control_wrapper
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


