#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-telegram-video-relay}"
APP_VERSION="v62"
DEFAULT_APP_DIR="/opt/tg-video-relay-bot"
APP_DIR_FROM_ENV="${APP_DIR:-}"
APP_DIR="${APP_DIR:-${DEFAULT_APP_DIR}}"
REPO_URL="${REPO_URL:-https://github.com/kingsnakerrr/tg-video-relay-bot.git}"
BRANCH="${BRANCH:-main}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
CONTROL_BIN="/usr/local/bin/x"
ALT_CONTROL_BIN="/usr/local/bin/tg-video-relay"
INSTALLER_VERSION="2026-07-09.12"
DENO_INSTALL_STATUS="skipped"
DEFAULT_DOWNLOAD_FORMAT="bv*+ba/best"
OLD_1080P_DOWNLOAD_FORMAT="bv*[height<=1080][ext=mp4]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]/best[height<=1080]/best"

retry_or_die() {
  local label="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "WARNING: ${label} failed. Retrying once..."
  echo "警告: ${label} 失败，自动重试一次..."
  sleep 2
  if "$@"; then
    return 0
  fi
  echo
  echo "ERROR: ${label} failed twice."
  echo "错误: ${label} 连续失败两次。"
  echo "After fixing the VPS/network issue, reinstall with / 修好 VPS 或网络后重新执行:"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)"
  exit 1
}

retry_optional() {
  local label="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "WARNING: ${label} failed. Retrying once..."
  echo "警告: ${label} 失败，自动重试一次..."
  sleep 2
  "$@"
}

install_deno_once() {
  curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip" -o "${DENO_TMP_DIR}/deno.zip" \
    && unzip -o "${DENO_TMP_DIR}/deno.zip" -d "${DENO_TMP_DIR}" \
    && install -m 755 "${DENO_TMP_DIR}/deno" /usr/local/bin/deno
}

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

backup_and_reset_dirty_checkout() {
  local repo_dir="$1"
  local backup_dir="/root/tg-video-relay-backups"
  local stamp=""
  local dirty=""

  [ -d "${repo_dir}/.git" ] || return 0
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
  echo "Resetting app code to match GitHub. .env/cookies/downloads are not tracked and are kept."
  echo "正在把程序代码重置为 GitHub 版本。.env、cookies、downloads 不受 Git 管理，会保留。"
  git -C "${repo_dir}" reset --hard HEAD
}

if [ "$(id -u)" -ne 0 ]; then
  die "Please run as root / 请用 root 运行，例如: sudo bash install.sh"
fi

echo "Telegram Video Relay ${APP_VERSION} installer ${INSTALLER_VERSION} / Telegram 视频转发机器人安装器 ${APP_VERSION} ${INSTALLER_VERSION}"

case "${1:-}" in
  uninstall)
    step "Uninstalling service / 卸载服务"
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    systemctl disable "${APP_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
    systemctl daemon-reload
    systemctl reset-failed "${APP_NAME}" 2>/dev/null || true
    echo "Uninstalled service. Kept app files: ${APP_DIR}"
    echo "已卸载服务，保留程序文件: ${APP_DIR}"
    exit 0
    ;;
  purge)
    if [ "${2:-}" != "--yes" ]; then
      echo "This will stop the bot and delete ${APP_DIR}."
      echo "这会停止机器人并删除 ${APP_DIR}。"
      read -r -p "Type DELETE to continue / 输入 DELETE 继续: " answer
      [ "${answer}" = "DELETE" ] || { echo "Cancelled. / 已取消。"; exit 1; }
    fi
    step "Purging install / 彻底删除安装"
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    systemctl disable "${APP_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${CONTROL_BIN}" "${ALT_CONTROL_BIN}"
    rm -rf "${APP_DIR}"
    systemctl daemon-reload
    systemctl reset-failed "${APP_NAME}" 2>/dev/null || true
    echo "Purged ${APP_NAME}. / 已彻底删除 ${APP_NAME}。"
    exit 0
    ;;
esac

if [ -z "${APP_DIR_FROM_ENV}" ]; then
  echo
  echo "Install directory / 安装目录"
  read -r -p "Use default ${DEFAULT_APP_DIR}? [Y/n] / 是否使用默认目录 ${DEFAULT_APP_DIR}? [Y/n]: " use_default_dir
  case "${use_default_dir}" in
    n|N|no|NO|No)
      read -r -p "Enter install directory / 请输入安装目录: " custom_app_dir
      [ -n "${custom_app_dir}" ] || die "Install directory cannot be empty. / 安装目录不能为空。"
      APP_DIR="${custom_app_dir}"
      ;;
  esac
else
  echo "Using APP_DIR from environment / 使用环境变量 APP_DIR: ${APP_DIR}"
fi

step "Installing system packages / 安装系统依赖"
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  retry_or_die "apt update" apt update
  retry_or_die "apt install packages" apt install -y git curl ca-certificates python3 python3-venv python3-pip ffmpeg unzip
else
  die "This installer currently supports Debian/Ubuntu with apt. / 当前脚本只支持 Debian/Ubuntu apt 系统。"
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [ -n "${SCRIPT_SOURCE}" ] && [ -f "${SCRIPT_SOURCE}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
fi

step "Preparing app directory / 准备程序目录: ${APP_DIR}"
mkdir -p "$(dirname "${APP_DIR}")"

if [ -n "${SCRIPT_DIR}" ] && has_project_files "${SCRIPT_DIR}"; then
  mkdir -p "${APP_DIR}"
  if [ "${SCRIPT_DIR}" != "${APP_DIR}" ]; then
    step "Copying local project files / 复制本地项目文件"
    tar \
      --exclude='./.env' \
      --exclude='./downloads' \
      --exclude='./.venv' \
      --exclude='./__pycache__' \
      -C "${SCRIPT_DIR}" -cf - . | tar -C "${APP_DIR}" -xf -
  fi
elif [ -d "${APP_DIR}/.git" ]; then
  step "Updating existing GitHub checkout / 更新现有 GitHub 项目"
  backup_and_reset_dirty_checkout "${APP_DIR}"
  retry_or_die "git fetch project" git -C "${APP_DIR}" fetch origin "${BRANCH}"
  retry_or_die "git checkout project branch" git -C "${APP_DIR}" checkout "${BRANCH}"
  retry_or_die "git pull project" git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
elif dir_is_not_empty "${APP_DIR}"; then
  if has_project_files "${APP_DIR}"; then
    step "Using existing project files / 使用现有项目文件"
  else
    BACKUP_DIR="${APP_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    step "${APP_DIR} exists but is not a valid install. Moving it to ${BACKUP_DIR} / ${APP_DIR} 已存在但不是有效安装，移动到 ${BACKUP_DIR}"
    mv "${APP_DIR}" "${BACKUP_DIR}"
    step "Cloning project from GitHub / 从 GitHub 克隆项目"
    retry_or_die "git clone project" git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
  fi
else
  step "Cloning project from GitHub / 从 GitHub 克隆项目"
  retry_or_die "git clone project" git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}"
has_project_files "${APP_DIR}" || die "Project files were not found in ${APP_DIR}. / ${APP_DIR} 中没有找到项目文件。"

step "Creating Python virtual environment / 创建 Python 虚拟环境"
retry_or_die "create Python venv" "${PYTHON_BIN}" -m venv .venv
. .venv/bin/activate
retry_or_die "upgrade pip" python -m pip install --upgrade pip
retry_or_die "install Python requirements" python -m pip install --upgrade -r requirements.txt
retry_or_die "install yt-dlp" python -m pip install --upgrade yt-dlp

if command -v deno >/dev/null 2>&1; then
  DENO_INSTALL_STATUS="already installed"
else
  step "Installing yt-dlp JavaScript runtime / 安装 yt-dlp JavaScript 运行时"
  DENO_TMP_DIR="$(mktemp -d)"
  if retry_optional "install Deno runtime" install_deno_once; then
    deno --version || true
    DENO_INSTALL_STATUS="installed"
  else
    DENO_INSTALL_STATUS="failed"
    echo "WARNING: Deno install failed. You can run x js-runtime-install later."
    echo "警告: Deno 自动安装失败。以后可以执行 x js-runtime-install。"
  fi
  rm -rf "${DENO_TMP_DIR}"
fi

if [ ! -f .env ]; then
  step "Creating .env / 创建配置文件 .env"
  echo "First-time setup inputs / 首次安装需要输入:"
  echo "  Telegram Bot Token / Telegram 机器人 Token"
  echo "  Target channel/group IDs / 目标频道或群组 ID，多个用英文逗号分隔"
  echo "  Admin Telegram user IDs / 管理员 Telegram 用户 ID，多个用英文逗号分隔"
  echo "  Download/cache directory / 下载视频缓存目录"
  echo "  Optional X/YouTube cookie sync links / 可选 X 和 YouTube cookies 同步直链"
  echo "  Optional Local Bot API credentials / 可选本地 Bot API 的 api_id 和 api_hash"
  echo "Default mode is Public Bot API. You can switch later with x local-api-switch."
  echo "默认先使用公网 Bot API 模式，Local Bot API 安装成功后可用 x local-api-switch 切换。"
  echo
  BOT_TOKEN="$(ask_required "Telegram Bot Token / Telegram 机器人 Token")"
  TARGET_CHAT_IDS="$(ask_required "Target channel/group IDs, comma separated / 目标频道或群组 ID，多个用英文逗号分隔")"
  ALLOWED_USER_IDS="$(ask_required "Admin Telegram user IDs, comma separated / 管理员 Telegram 用户 ID，多个用英文逗号分隔")"
  DEFAULT_DOWNLOAD_DIR="${APP_DIR}/downloads"
  read -r -p "Download/cache directory [${DEFAULT_DOWNLOAD_DIR}] / 下载视频缓存目录 [${DEFAULT_DOWNLOAD_DIR}]: " DOWNLOAD_DIR_INPUT
  DOWNLOAD_DIR_VALUE="${DOWNLOAD_DIR_INPUT:-${DEFAULT_DOWNLOAD_DIR}}"
  read -r -p "Optional X cookies sync link, press Enter to skip / 可选 X cookies 同步链接，回车跳过: " COOKIE_SYNC_URL_X
  read -r -p "Optional YouTube cookies sync link, press Enter to skip / 可选 YouTube cookies 同步链接，回车跳过: " COOKIE_SYNC_URL_YOUTUBE
  read -r -p "Optional Local Bot API ID, press Enter to skip / 可选 Local Bot API ID，回车跳过: " LOCAL_API_ID
  if [ -n "${LOCAL_API_ID}" ]; then
    read -r -s -p "Optional Local Bot API hash / 可选 Local Bot API hash: " LOCAL_API_HASH
    echo
    if [ -n "${LOCAL_API_HASH}" ]; then
      cat > /etc/telegram-bot-api.env <<EOF_LOCAL_API_ENV
TELEGRAM_API_ID=${LOCAL_API_ID}
TELEGRAM_API_HASH=${LOCAL_API_HASH}
EOF_LOCAL_API_ENV
      chmod 600 /etc/telegram-bot-api.env
      echo "Saved Local Bot API credentials to /etc/telegram-bot-api.env"
      echo "已保存 Local Bot API 参数到 /etc/telegram-bot-api.env"
    else
      echo "Local Bot API hash empty, skipped. / Local Bot API hash 为空，已跳过。"
    fi
  fi
  SUBMIT_API_SECRET="$(generate_secret)"

  cat > .env <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
BOT_API_BASE_URL=https://api.telegram.org
BOT_API_USE_LOCAL_FILE_URI=false
TARGET_CHAT_IDS=${TARGET_CHAT_IDS}
ALLOWED_USER_IDS=${ALLOWED_USER_IDS}
DOWNLOAD_DIR=${DOWNLOAD_DIR_VALUE}
DOWNLOAD_FORMAT=${DEFAULT_DOWNLOAD_FORMAT}
MERGE_OUTPUT_FORMAT=mp4
MAX_FILE_MB=1900
MAX_UPLOAD_MB=49
AUTO_COMPRESS=true
COMPRESS_AUDIO_KBPS=96
COMPRESS_MIN_VIDEO_KBPS=60
YTDLP_FORCE_IPV4=true
YTDLP_HTTP_CHUNK_SIZE=10M
YOUTUBE_PLAYER_CLIENTS=web,web_safari,ios,android
COOKIES_FILE=
COOKIES_FILE_X=${APP_DIR}/cookies_x.txt
COOKIES_FILE_YOUTUBE=${APP_DIR}/cookies_youtube.txt
COOKIE_SYNC_URL=
COOKIE_SYNC_URL_X=${COOKIE_SYNC_URL_X}
COOKIE_SYNC_URL_YOUTUBE=${COOKIE_SYNC_URL_YOUTUBE}
COOKIE_SYNC_INTERVAL_MINUTES=360
UPLOAD_MODE=video
DELETE_AFTER_ALL_UPLOADS=true
BOT_API_TIMEOUT=30
UPLOAD_TIMEOUT=1800
UPLOAD_RETRIES=3
POLL_TIMEOUT=50
WORKER_COUNT=1
TELEGRAM_RESOLUTION_MENU=true
TELEGRAM_RESOLUTION_AUTO_SECONDS=3
SUBMIT_API_ENABLED=true
SUBMIT_API_HOST=0.0.0.0
SUBMIT_API_PORT=8787
SUBMIT_API_SECRET=${SUBMIT_API_SECRET}
SUBMIT_NOTIFY_CHAT_ID=
EOF_ENV
else
  step "Existing .env found, keeping it / 已找到现有 .env，保留不覆盖"
fi

grep -q '^MAX_UPLOAD_MB=' .env || printf '\nMAX_UPLOAD_MB=49\n' >> .env
grep -q '^DOWNLOAD_DIR=' .env || printf 'DOWNLOAD_DIR=%s/downloads\n' "${APP_DIR}" >> .env
if grep -Fqx "DOWNLOAD_FORMAT=${OLD_1080P_DOWNLOAD_FORMAT}" .env; then
  sed -i "s|^DOWNLOAD_FORMAT=.*|DOWNLOAD_FORMAT=${DEFAULT_DOWNLOAD_FORMAT}|" .env
fi
grep -q '^DOWNLOAD_FORMAT=' .env || printf 'DOWNLOAD_FORMAT=%s\n' "${DEFAULT_DOWNLOAD_FORMAT}" >> .env
grep -q '^BOT_API_BASE_URL=' .env || printf 'BOT_API_BASE_URL=https://api.telegram.org\n' >> .env
grep -q '^BOT_API_USE_LOCAL_FILE_URI=' .env || printf 'BOT_API_USE_LOCAL_FILE_URI=false\n' >> .env
grep -q '^AUTO_COMPRESS=' .env || printf 'AUTO_COMPRESS=true\n' >> .env
grep -q '^COMPRESS_AUDIO_KBPS=' .env || printf 'COMPRESS_AUDIO_KBPS=96\n' >> .env
grep -q '^COMPRESS_MIN_VIDEO_KBPS=' .env || printf 'COMPRESS_MIN_VIDEO_KBPS=60\n' >> .env
grep -q '^UPLOAD_RETRIES=' .env || printf 'UPLOAD_RETRIES=3\n' >> .env
grep -q '^YTDLP_FORCE_IPV4=' .env || printf 'YTDLP_FORCE_IPV4=true\n' >> .env
grep -q '^YTDLP_HTTP_CHUNK_SIZE=' .env || printf 'YTDLP_HTTP_CHUNK_SIZE=10M\n' >> .env
grep -q '^YOUTUBE_PLAYER_CLIENTS=' .env || printf 'YOUTUBE_PLAYER_CLIENTS=web,web_safari,ios,android\n' >> .env
grep -q '^TELEGRAM_RESOLUTION_MENU=' .env || printf 'TELEGRAM_RESOLUTION_MENU=true\n' >> .env
grep -q '^TELEGRAM_RESOLUTION_AUTO_SECONDS=' .env || printf 'TELEGRAM_RESOLUTION_AUTO_SECONDS=3\n' >> .env
if grep -q '^COOKIES_FILE=$' .env; then
  sed -i "s|^COOKIES_FILE=$|COOKIES_FILE=|" .env
fi
if grep -q "^COOKIES_FILE=${APP_DIR}/cookies.txt$" .env; then
  sed -i "s|^COOKIES_FILE=${APP_DIR}/cookies.txt$|COOKIES_FILE=|" .env
fi
grep -q '^COOKIES_FILE=' .env || printf 'COOKIES_FILE=\n' >> .env
grep -q '^COOKIES_FILE_X=' .env || printf 'COOKIES_FILE_X=%s/cookies_x.txt\n' "${APP_DIR}" >> .env
grep -q '^COOKIES_FILE_YOUTUBE=' .env || printf 'COOKIES_FILE_YOUTUBE=%s/cookies_youtube.txt\n' "${APP_DIR}" >> .env
grep -q '^COOKIE_SYNC_URL=' .env || printf 'COOKIE_SYNC_URL=\n' >> .env
grep -q '^COOKIE_SYNC_URL_X=' .env || printf 'COOKIE_SYNC_URL_X=\n' >> .env
grep -q '^COOKIE_SYNC_URL_YOUTUBE=' .env || printf 'COOKIE_SYNC_URL_YOUTUBE=\n' >> .env
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
DOWNLOAD_DIR_CURRENT="$(grep -E '^DOWNLOAD_DIR=' .env | tail -n 1 | cut -d= -f2-)"
[ -n "${DOWNLOAD_DIR_CURRENT}" ] || DOWNLOAD_DIR_CURRENT="${APP_DIR}/downloads"
mkdir -p "${DOWNLOAD_DIR_CURRENT}"
for cookie_file in "${APP_DIR}/cookies.txt" "${APP_DIR}/cookies_x.txt" "${APP_DIR}/cookies_youtube.txt"; do
  [ -f "${cookie_file}" ] && chmod 600 "${cookie_file}"
done

step "Writing systemd service / 写入 systemd 服务"
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

step "Installing control command / 安装控制命令"
if [ -f "${APP_DIR}/control.sh" ]; then
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
else
  echo "WARNING: control.sh not found; skipping ${CONTROL_BIN}"
  echo "警告: 找不到 control.sh，跳过 ${CONTROL_BIN}"
fi

step "Starting service / 启动服务"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

echo
echo "Installed successfully. / 安装成功。"
echo "App dir / 程序目录: ${APP_DIR}"
echo "Menu / 菜单:        x"
echo "Status / 状态:      x status"
echo "Logs / 日志:        x logs"
echo "Stop / 停止:        x stop"
echo "Start / 启动:       x start"
echo "Shortcut / 快捷指令:x shortcut"
echo "Remove / 卸载:      x uninstall"
echo "Update / 更新:      bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)"
echo
echo "yt-dlp JS runtime / yt-dlp JS 运行时: ${DENO_INSTALL_STATUS}"
if [ "${DENO_INSTALL_STATUS}" = "failed" ]; then
  echo
  echo "Manual Deno install / Deno 手动安装:"
  echo "  x js-runtime-install"
fi
echo
echo "Local Bot API low-memory install / Local Bot API 低内存安装:"
echo "  Normal install does not create swap. Local Bot API uses BUILD_JOBS=1 by default."
echo "  普通安装不会增加虚拟内存。Local Bot API 默认用 BUILD_JOBS=1 单线程编译。"
echo "  If you really need swap for compiling, run / 如果编译确实需要 swap，再执行:"
echo "  ENABLE_SWAP=true BUILD_JOBS=1 x local-api-install"
echo
echo "If Local Bot API install fails, rerun / 如果 Local Bot API 安装失败，重新执行:"
echo "  x local-api-install"
echo "Or use background build / 或后台编译:"
echo "  BUILD_JOBS=1 x local-api-install-bg"
echo "  x local-api-install-log"
