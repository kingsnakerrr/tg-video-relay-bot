# Telegram Video Relay Bot

把 X/Twitter、TikTok、抖音、YouTube 等公开视频链接转发给 Telegram 机器人，机器人会在 VPS 上下载视频，然后发送到配置好的多个频道或群组。任务结束后，本地视频会自动清理。

请只下载和转发你拥有权利或已获授权的视频，并遵守平台条款。这个项目不绕过 DRM、付费墙或私密内容访问限制。

## 功能

- 支持 Telegram 私聊/群聊里发送链接触发任务
- 支持多个目标频道/群组
- 支持 `@channelusername` 和 `-100...` chat id
- 下载完成后可作为视频或文件发送
- 上传成功或失败后都会自动清理本地任务文件
- v34：YouTube 清晰度按钮会尽量过滤 yt-dlp 标记的 DRM/受限格式，并用具体非受限格式 ID 下载，减少误选 HDR/受限流导致失败
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

- Telegram Bot Token
- 目标频道/群组 ID，多个用英文逗号隔开
- 管理员 Telegram 用户 ID，多个用英文逗号隔开

安装完成后直接输入：

```bash
x
```

会出现控制菜单。看日志也可以用：

```bash
x logs
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

也可以让 VPS 从你的 OneDrive/OpenList 私密直链自动同步 X cookies：

```env
COOKIES_FILE_X=/opt/tg-video-relay-bot/cookies_x.txt
COOKIE_SYNC_URL=https://你的私密直链/cookies.txt
COOKIE_SYNC_INTERVAL_MINUTES=360
```

保存后执行：

```bash
x cookies
x restart
```

检查链接是不是直链：

```bash
curl -L "你的COOKIE_SYNC_URL" | head
```

正确内容通常会看到：

```text
# Netscape HTTP Cookie File
```

如果看到 `<html`、登录页、OneDrive 预览页，就不是直链。OpenList 建议使用文件的直接下载地址；OneDrive 分享页通常不是直链。

不要把 cookie 文件提交到公开仓库，也不要使用任何人都能访问的公开直链。

## 常见问题

- 上传失败：确认机器人在目标频道/群组里有发消息权限。
- YouTube 默认最高 1080p：`DOWNLOAD_FORMAT=bv*[height<=1080][ext=mp4]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]/best[height<=1080]/best`。想 1080p 且不压缩，先装好 Local Bot API，然后执行 `x 1080p`。
- Telegram 里直接发链接会返回可下载清晰度按钮，点选后才开始下载。iPhone 快捷指令不会弹按钮，会直接按默认最高 1080p 下载；源视频不到 1080p 时自动拿最高可用。
- 清晰度选择界面有“取消下载”按钮，X 和 YouTube 链接都支持。
- 如果 YouTube 清晰度解析失败，机器人会先用“自动可用格式”兜底下载，避免任务直接死掉。想恢复 1080p/4K 选择，重点检查 `/opt/tg-video-relay-bot/cookies_youtube.txt` 是否有效。
- 如果 YouTube 明明有 1080p/4K，但按钮只显示 360p，或选 1080p 后提示 403，通常是 YouTube 给 VPS/当前 yt-dlp client 限制了格式或下载地址。先执行 `x ytdlp-update`、`x 1080p`、`x restart`，再用 `x doctor` 确认 `YOUTUBE_PLAYER_CLIENTS=web,web_safari,ios,android`；仍不行就给 `COOKIES_FILE` 配置 YouTube 登录 cookies。
- 如果下载提示是 1080p，但上传后看着糊，先看机器人提示里的“上传文件”分辨率。公网 Bot API 模式超过约 50MB 会自动压缩，可能从 1080p 压到 720p/480p/360p。真正不压缩要安装并启用 Local Bot API，然后执行 `x original`。
- 下载后无论上传成功、上传失败还是任务失败，本地任务文件都会自动清理，避免占用 VPS 空间。
- 不想在 Telegram 里选清晰度：把 `.env` 里的 `TELEGRAM_RESOLUTION_MENU=false`，然后执行 `x restart`。
- 视频太大：公网 Bot API 只能约 50MB；不想压缩请用 `x local-api` 安装本地 Bot API，再用 `x 1080p`。
- Telegram 不识别视频：把 `UPLOAD_MODE=document`，会作为文件发送。
- YouTube/TikTok/X/Douyin 下载失败：升级 `yt-dlp`：`pip install -U yt-dlp`。
- `Request Entity Too Large`：视频超过公共 Telegram Bot API 上传限制。默认 `MAX_UPLOAD_MB=49` 且 `AUTO_COMPRESS=true` 会自动压缩后再上传。改完 `.env` 后执行 `systemctl restart telegram-video-relay`。
