# Telegram Video Relay Bot

Update v74: Chrome extension updates now inject the copy/right-click listener into already-open X, YouTube and Pornhub tabs, with a duplicate-injection guard.

Update v73: Pornhub regional hosts such as cn.pornhub.com are normalized to www.pornhub.com, and the Chrome extension now runs on every Pornhub subdomain so copied links trigger the confirmation popup.

Update v72: Pornhub downloads now retry with a real Chrome TLS/browser fingerprint through yt-dlp and curl-cffi before using the normal request path.

Update v71: added Pornhub video URL support, optional independent cookies/sync settings, and Chrome right-click/copy submission support. Public videos usually work without cookies; restricted/login-required videos can use `cookies_pornhub.txt`.

Update v70: Chrome right-click menu now submits the video/post/link you clicked directly; copied-link prompting remains separate.

Update v69: Chrome copy popup now asks once per copy action, so copying the same URL again after cancel will prompt again.

Update v68: Chrome copy popup now stops after one confirm/cancel per copied URL, preventing repeated submit prompts.

Update v67: Chrome extension watches the clipboard for several seconds after copy/click so X/YouTube copied links can trigger the confirm popup more reliably.

Update v66: Page right-click send menu is restored; enable/disable remains only on the extension icon right-click. Copy detection also checks click/mouseup/keyboard copy events.

Update v65: Chrome extension menus now appear only when right-clicking the extension icon. Left-click submits the copied URL; icon right-click has enable/disable.

Update v64: Chrome extension prompts only for copied X/YouTube video URLs, ignores other copied text, supports enable/disable menu, and left-click submits copied URL.

Update v63: Chrome extension supports YouTube Shorts URLs such as https://youtube.com/shorts/VIDEO_ID.

把 X/Twitter、TikTok、抖音、YouTube 等公开视频链接转发给 Telegram 机器人，机器人会在 VPS 上下载视频，然后发送到配置好的多个频道或群组。任务结束后，本地视频会自动清理。

请只下载和转发你拥有权利或已获授权的视频，并遵守平台条款。这个项目不绕过 DRM、付费墙或私密内容访问限制。

## 功能

- 支持 Telegram 私聊/群聊里发送链接触发任务
- 支持多个目标频道/群组
- 支持 `@channelusername` 和 `-100...` chat id
- 下载完成后可作为视频或文件发送
- 上传成功或失败后都会自动清理本地任务文件
- v34：YouTube 清晰度按钮会尽量过滤 yt-dlp 标记的 DRM/受限格式，并用具体非受限格式 ID 下载，减少误选 HDR/受限流导致失败
- v35：新增 `x youtube-cookies-test URL`，可直接检测 YouTube cookies 文件、Netscape 格式和 yt-dlp 可解析清晰度
- v36：明确选择清晰度后不再静默降级到低清 fallback，并在下载完成消息里显示 yt-dlp 实际 format id/分辨率
- v37：新增 `x js-runtime-install` 安装 Deno，修复 yt-dlp 提示缺少 YouTube JavaScript runtime 导致格式缺失的问题
- v38：新增 `x logs-recent`，并记录 YouTube 格式探测、实际下载 format selector、client 和 yt-dlp 原始错误
- v39：修复 YouTube 某些格式只在 default client 可用时，下载阶段首个 client 失败后没有继续尝试其它 client 的问题
- v40：新增 X/YouTube 独立 cookies 同步链接配置，支持 Google Drive 分享链接自动转直链，菜单可手动配置和同步
- v41：Telegram 上传遇到连接中断、RemoteDisconnected 或 5xx 时自动重试，默认 `UPLOAD_RETRIES=3`
- v42：新增 Telegram 机器人内管理员按钮菜单和斜杠菜单，可在 TG 里执行状态、日志、更新、重启、停止、同步 cookies 等操作
- v43：精简 VPS `x` 主菜单，合并 cookies 状态/直链设置/同步入口，安装时自动安装 yt-dlp JS runtime
- v44：安装时自动尝试安装 Deno/yt-dlp JS runtime，失败也继续安装；安装结束显示手动安装、swap 虚拟内存和低内存 Local Bot API 编译命令
- v45：安装步骤失败会自动重试一次；Local Bot API 默认按低内存方式安装，`BUILD_JOBS=1`；旧版曾自动准备 swap，v48 起默认不自动创建
- v46：修复 Debian trixie/Python 3.13 删除 `cgi` 标准库导致 HTTP submit API 启动失败的问题
- v47：安装时可输入下载视频缓存目录，安装后可用 `x download-dir` 查看和修改
- v48：安装时可选择安装目录，`x` 命令会自动绑定该目录；Telegram 发链接后 3 秒内可选清晰度，超时自动下载最高画质；默认下载最高可用，不再限制 1080p；Local Bot API 默认不自动创建 swap；新增 `x chrome` 显示电脑 Chrome 提交配置
- v49：修复 VPS 目录里有本地 Git 改动时无法升级的问题；升级前会把本地改动备份到 `/root/tg-video-relay-backups`，再同步 GitHub
- v50：`x chrome` 改为生成真正的 Chrome 右键扩展包，右键页面/链接即可带密钥提交到 VPS 下载最高画质
- v51：修复 Chrome 扩展生成时 icon base64 报错的问题，改用扩展徽标显示 OK/ERR
- v52：修复 Chrome 扩展 Service Worker 无效的问题，提交地址和密钥改用 JSON 安全转义写入后台脚本
- v53：简化 Chrome 扩展为最小稳定右键版，移除 content script 和 tabs 消息通道，避免 Service Worker 再次失效
- v54：Chrome 扩展文件改为 Python 生成，避免 Bash 展开 JavaScript 模板字符串导致 Service Worker 失效
- v62：Chrome 扩展改为后台 fetch 提交，不再打开 /submit 标签页
- v61：Chrome/HTTP 提交 YouTube 链接时先探测清晰度并用最高具体 format id 下载，避免 yt-dlp 默认误选 360p format 18；安装包脚本统一 LF
- v60：Chrome 扩展禁止误发 x.com/home；右键发送时剪贴板读不到会弹输入框手动粘贴真实链接
- v59：Chrome 扩展改为“先复制真实链接，再右键发送”，右键提交时优先读取剪贴板；菜单提示改用 IP 示例
- v58：Chrome 扩展支持点 X 自带“复制链接”后弹窗确认发送；8787 提交地址强制使用 http://，避免误开 https
- v57：Chrome 右键扩展增加右键位置缓存，提交时优先使用真实 X 帖子链接；裸域名提交地址默认补 http://，避免 8787 被误当 https
- v56：Chrome 右键扩展会从 X 帖子卡片里自动识别真实 /status/ 链接，避免在首页右键只提交 x.com/home
- v55：Chrome 扩展提交方式从 fetch 改为后台标签页 GET 提交，避开 CORS/fetch Failed to fetch 问题
- `/id` 查看当前用户和聊天 ID
- `/targets` 查看当前转发目标数量
- `/status` 查看队列状态

## VPS 安装

### 一键安装

如果你把项目上传到 GitHub 仓库：

```text
https://github.com/kingsnakerrr/tg-video-relay-bot
```

VPS 上可以直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)
```

安装脚本会提示你输入：

- 是否使用默认安装目录 `/opt/tg-video-relay-bot`，也可以输入 `/data/opt/tg-video-relay-bot` 等自定义目录
- Telegram Bot Token
- 目标频道/群组 ID，多个用英文逗号隔开
- 管理员 Telegram 用户 ID，多个用英文逗号隔开
- 下载视频缓存目录，默认是安装目录下的 `downloads`
- X cookies 同步链接，可回车跳过
- YouTube cookies 同步链接，可回车跳过
- Local Bot API `api_id` 和 `api_hash`，可回车跳过，后面还能用 `x local-api` 配置

安装完成后直接输入：

```bash
x
```

会出现控制菜单。看日志也可以用：

```bash
x logs
```

### 下载视频缓存目录

安装时会提示输入下载视频缓存目录。默认是安装目录下的 `downloads`，例如：

```text
/data/opt/tg-video-relay-bot/downloads
```

这里保存的是下载完成、上传到 Telegram 前的临时视频文件。任务完成后会按配置自动清理。安装后可以随时查看或修改：

```bash
x download-dir
```

也可以直接编辑 `.env`：

```env
DOWNLOAD_DIR=/data/opt/tg-video-relay-bot/downloads
```

### 电脑 Chrome 右键提交

安装完成后执行：

```bash
x chrome http://143.20.156.100:8787/submit
```

如果你用了 HTTPS 反代，也可以：

```bash
x chrome http://143.20.156.100:8787/submit
```

命令会生成：

```text
/data/opt/tg-video-relay-bot/chrome-tg-relay-extension.zip
```

把这个 zip 下载到电脑解压，Chrome 打开 `chrome://extensions`，开启开发者模式，点“加载已解压的扩展程序”，选择解压后的 `chrome-tg-relay-extension` 文件夹。以后在 X/YouTube/Pornhub 视频页面或链接上右键，选择 TG Relay 提交菜单即可。

注意：扩展包里包含你的 `SUBMIT_API_SECRET`，不要上传到公开仓库。

### 安装失败重试和低内存 Local Bot API

安装脚本里安装程序、Python 依赖、yt-dlp、Deno 等步骤如果失败，会自动重试一次。第二次还失败，脚本会停下来并提示重新执行一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)
```

`Install yt-dlp JS runtime` 只是给 YouTube 解析用的 Deno，不是之前爆内存的东西；如果它失败，后面可以手动执行：

```bash
x js-runtime-install
```

真正容易爆内存的是 Local Bot API 的 `telegram-bot-api` 源码编译。现在 `x local-api-install` 默认就是低内存安装，会用 `BUILD_JOBS=1` 单线程编译，但不会自动创建 swap：

```bash
x local-api-install
```

如果编译时确实因为内存不足被 killed，再明确启用 swap：

```bash
ENABLE_SWAP=true BUILD_JOBS=1 x local-api-install
```

如果 Local Bot API 安装失败，直接重新执行上面的命令；也可以后台编译并查看日志：

```bash
BUILD_JOBS=1 x local-api-install-bg
x local-api-install-log
```

### 手动安装

Ubuntu/Debian 示例：

```bash
sudo apt update
sudo apt install -y python3 python3-venv ffmpeg
cd /opt
sudo git clone <your-repo-or-uploaded-folder> tg-video-relay-bot
cd /opt/tg-video-relay-bot
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
nano .env
```

至少填写：

```env
BOT_TOKEN=你的机器人Token
TARGET_CHAT_IDS=-1001234567890,@your_channel_username
ALLOWED_USER_IDS=你的Telegram数字用户ID
```

然后运行：

```bash
. .venv/bin/activate
python -m tg_video_relay_bot
```

## Telegram 配置

1. 用 `@BotFather` 创建机器人并拿到 `BOT_TOKEN`。
2. 把机器人加入要发布的频道或群组。
3. 频道里要把机器人设为管理员，并允许发消息/发视频。
4. 给机器人发送 `/id`，把返回的用户 ID 填进 `ALLOWED_USER_IDS`。
5. 群组/频道的数字 ID 通常是 `-100...`。你也可以对公开频道使用 `@channelusername`。

## Telegram 内控制命令

管理员可以直接在 Telegram 机器人里发送：

```text
/menu      打开按钮菜单
/help      显示所有命令
/status    查看状态
/logs      查看最近日志
/cookies   手动同步 cookies
/ytdlp     更新 yt-dlp
/update    更新项目并重启
/restart   重启机器人
/stop      停止/暂停机器人
/id        查看用户和聊天 ID
/targets   查看转发目标
```

`/menu` 会显示可点击按钮。注意：点 `/stop` 后机器人停止，Telegram 里无法再收到启动命令，需要 SSH 执行 `x start`。

## iPhone 快捷指令入口

本项目内置私密 HTTP 提交入口，给 iPhone 快捷指令使用。安装后执行：

```bash
x shortcut
```

它会显示快捷指令需要填的 URL 和 `secret`。详细步骤见 `SHORTCUT.md`。

## systemd 常驻运行

复制服务文件：

```bash
sudo cp deploy/telegram-video-relay.service /etc/systemd/system/telegram-video-relay.service
sudo nano /etc/systemd/system/telegram-video-relay.service
```

按你的 VPS 用户和目录调整：

```ini
User=ubuntu
WorkingDirectory=/opt/tg-video-relay-bot
EnvironmentFile=/opt/tg-video-relay-bot/.env
ExecStart=/opt/tg-video-relay-bot/.venv/bin/python -m tg_video_relay_bot
```

启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now telegram-video-relay
sudo systemctl status telegram-video-relay
```

查看日志：

```bash
journalctl -u telegram-video-relay -f
```

## Cookie 登录

部分平台或年龄限制视频可能需要 cookie。请使用 Netscape 格式 cookie 文件。

默认分开保存：

```text
/opt/tg-video-relay-bot/cookies_x.txt
/opt/tg-video-relay-bot/cookies_youtube.txt
```

X/Twitter 链接自动读取 `cookies_x.txt`，YouTube 链接自动读取 `cookies_youtube.txt`。

把旧 X cookies 迁移到新路径：

```bash
cd /opt/tg-video-relay-bot
cp cookies.txt cookies_x.txt
chmod 600 cookies_x.txt
x cookies
x restart
```

YouTube cookies 上传到 VPS：

```text
/opt/tg-video-relay-bot/cookies_youtube.txt
```

然后执行：

```bash
cd /opt/tg-video-relay-bot
chmod 600 cookies_youtube.txt
x restart
```

`.env` 里保持：

```env
COOKIES_FILE=
COOKIES_FILE_X=/opt/tg-video-relay-bot/cookies_x.txt
COOKIES_FILE_YOUTUBE=/opt/tg-video-relay-bot/cookies_youtube.txt
```

也可以让 VPS 从你的 Google Drive/OneDrive/OpenList 私密直链自动同步 cookies：

```env
COOKIES_FILE_X=/opt/tg-video-relay-bot/cookies_x.txt
COOKIES_FILE_YOUTUBE=/opt/tg-video-relay-bot/cookies_youtube.txt
COOKIE_SYNC_URL_X=https://你的私密直链/cookies_x.txt
COOKIE_SYNC_URL_YOUTUBE=https://你的私密直链/cookies_youtube.txt
COOKIE_SYNC_INTERVAL_MINUTES=360
```

Google Drive 的 `/file/d/.../view?...` 分享链接可以直接填，脚本会自动转换为下载链接。保存后执行：

```bash
x cookies-config
x cookies
x restart
```

检查链接是不是直链：

```bash
curl -L "你的COOKIE_SYNC_URL_X" | head
```

正确内容通常会看到：

```text
# Netscape HTTP Cookie File
```

如果看到 `<html`、登录页、OneDrive 预览页，就不是直链。OpenList 建议使用文件的直接下载地址；Google Drive 分享页会由脚本自动转下载链接。

不要把 cookie 文件提交到公开仓库，也不要使用任何人都能访问的公开直链。

## 常见问题

- 上传失败：确认机器人在目标频道/群组里有发消息权限。
- 默认下载最高可用：`DOWNLOAD_FORMAT=bv*+ba/best`。想大文件不压缩，先装好 Local Bot API，然后执行 `x local`。
- Telegram 里直接发链接会返回可下载清晰度按钮，3 秒内可手动点选；不点就自动下载最高画质。iPhone 快捷指令和电脑 Chrome 提交不会弹按钮，会直接按默认最高可用下载。
- 清晰度选择界面有“取消下载”按钮，X 和 YouTube 链接都支持。
- 如果 YouTube 清晰度解析失败，机器人会先用“自动可用格式”兜底下载，避免任务直接死掉。想恢复 1080p/4K 选择，重点检查 `/opt/tg-video-relay-bot/cookies_youtube.txt` 是否有效。
- 如果 YouTube 明明有 1080p/4K，但按钮只显示 360p，或选择后提示 403，通常是 YouTube 给 VPS/当前 yt-dlp client 限制了格式或下载地址。先执行 `x ytdlp-update`、`x restart`，再用 `x doctor` 确认 `YOUTUBE_PLAYER_CLIENTS=web,web_safari,ios,android`；仍不行就更新 YouTube 登录 cookies。
- 如果下载提示是高分辨率，但上传后看着糊，先看机器人提示里的“上传文件”分辨率。公网 Bot API 模式超过约 50MB 会自动压缩，可能从高分辨率压到 720p/480p/360p。真正不压缩要安装并启用 Local Bot API，然后执行 `x local`。
- 下载后无论上传成功、上传失败还是任务失败，本地任务文件都会自动清理，避免占用 VPS 空间。
- 不想在 Telegram 里选清晰度：把 `.env` 里的 `TELEGRAM_RESOLUTION_MENU=false`，然后执行 `x restart`。
- 视频太大：公网 Bot API 只能约 50MB；不想压缩请用 `x local-api` 安装本地 Bot API，再用 `x local`。
- Telegram 不识别视频：把 `UPLOAD_MODE=document`，会作为文件发送。
- YouTube/TikTok/X/Douyin 下载失败：升级 `yt-dlp`：`pip install -U yt-dlp`。
- `Request Entity Too Large`：视频超过公共 Telegram Bot API 上传限制。默认 `MAX_UPLOAD_MB=49` 且 `AUTO_COMPRESS=true` 会自动压缩后再上传。改完 `.env` 后执行 `systemctl restart telegram-video-relay`。
