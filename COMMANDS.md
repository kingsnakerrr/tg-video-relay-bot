# 控制命令

安装完成后，VPS 上直接输入：

```bash
x
```

会出现菜单，可以选择启动、暂停、重启、日志、同步 cookies、更新、卸载等操作。

也可以直接执行短命令：

```bash
x start       # 启动
x stop        # 暂停/停止
x pause       # 暂停/停止
x restart     # 重启
x status      # 查看状态
x doctor      # 诊断服务和 8787 接口
x mode        # 查看当前上传模式和两个模式状态
x 1080p       # 兼容旧命令：设置最高可用 + 本地原画质不压缩
x original    # 切到本地 Bot API 原画质不压缩上传
x local       # 切到本地 Bot API 原画质模式
x public      # 切回公网 Bot API 兼容模式
x ytdlp-update # 更新 yt-dlp，修复 YouTube/TikTok 常见下载失败
x ytdlp-version # 查看 yt-dlp 版本
x test-submit "https://x.com/..." # 从 VPS 本地测试提交
x logs        # 实时日志
x local-api   # 安装/配置 Local Bot API Server
x fix-env     # 补齐缺少的 .env 默认配置
x cookies     # 立即同步 cookies.txt
x download-dir # 查看或修改下载视频缓存目录
x shortcut    # 查看 iPhone 快捷指令配置
x chrome http://你的域名:8787/submit # 生成电脑 Chrome 右键提交扩展
x env         # 修改 .env 配置
x update      # 更新代码并重启
x reinstall   # 重新执行安装
x uninstall   # 卸载服务，保留 /opt/tg-video-relay-bot 和 .env
x purge       # 彻底删除服务和 /opt/tg-video-relay-bot
```

Telegram 里直接发链接会先显示可选清晰度按钮，3 秒内不选会自动下载最高画质。iPhone 快捷指令和 Chrome 右键扩展提交不会弹按钮，会直接按默认最高可用下载。

关闭 Telegram 清晰度选择：

```env
TELEGRAM_RESOLUTION_MENU=false
```

保存后：

```bash
x restart
```

旧命令 `tg-video-relay` 也会保留，但以后记 `x` 就行。

## Cookie 同步

手动上传：

```bash
cd /opt/tg-video-relay-bot
chmod 600 cookies.txt
x restart
```

自动同步：

```bash
x env
```

设置：

```env
COOKIES_FILE=/opt/tg-video-relay-bot/cookies.txt
COOKIE_SYNC_URL=https://你的私密直链/cookies.txt
COOKIE_SYNC_INTERVAL_MINUTES=360
```

保存后：

```bash
x cookies
x restart
```

`COOKIE_SYNC_URL` 必须是直接下载 cookies.txt 的私密链接，不要用公开链接。

检查链接是不是直链：

```bash
curl -L "你的COOKIE_SYNC_URL" | head
```

正确内容通常会看到：

```text
# Netscape HTTP Cookie File
```

如果看到 `<html`、登录页、OneDrive 预览页，就不是直链。OpenList 建议使用文件的直接下载地址；OneDrive 分享页通常不是直链。

## iPhone 快捷指令

查看快捷指令需要填的地址和密钥：

```bash
x shortcut
```

快捷指令里使用：

```text
获取输入中的 URL
获取 URL 内容
方法：POST
请求体：表单
键 secret，值 = x shortcut 显示的密钥
键 url，值 = 快捷指令输入 URL 变量
```

详细步骤见 `SHORTCUT.md`。

## 删除后重装

彻底删除：

```bash
x purge
```

重新安装：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh?ts=$(date +%s)")
```

## 常用排查

看日志：

```bash
x logs
```

改配置：

```bash
x env
x restart
```

## 原画质大文件

查看当前上传模式：

```bash
x quality
```

公网 Telegram Bot API 模式建议保持：

```env
MAX_UPLOAD_MB=49
AUTO_COMPRESS=true
```

不想降低画质，需要先在 VPS 上运行官方 Local Bot API Server，然后在 `x env` 里设置：

```env
BOT_API_BASE_URL=http://127.0.0.1:8081
BOT_API_USE_LOCAL_FILE_URI=true
MAX_UPLOAD_MB=1900
AUTO_COMPRESS=false
```

保存后执行：

```bash
x restart
```

详细说明见 `LOCAL_BOT_API.md`。

新版也可以直接用菜单：

```bash
x local-api
```

常用短命令：

```bash
x 1080p             # 兼容旧命令：最高可用；本地 Bot API 可用时自动不压缩
x local-api-install  # 安装/更新官方 telegram-bot-api
x local-api-switch   # 切到本地原画质大文件模式
x local-api-status   # 查看本地 API 状态
x local-api-logs     # 看本地 API 日志
x local-api-public   # 切回公网 50MB + 自动压缩模式
```
