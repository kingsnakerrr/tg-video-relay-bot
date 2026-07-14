# 原画质大文件上传

你现在遇到的 `Compressed file is still too large` 不是会员问题。普通 Telegram Bot API 上传文件有 50 MB 左右限制，Telegram Premium 用户身份不会提高机器人公网 API 的上传上限。

想不压缩、尽量保持原画质，有两个路线：

1. 推荐：官方 Local Bot API Server。机器人还是机器人，但上传走 VPS 本机的 Bot API 服务，可以上传 2 GB 左右文件，并且可以让 Bot API 直接读取 VPS 本地视频文件。
2. 不推荐：用户号/MTProto 上传。这个需要用你的 Telegram 账号登录，维护会话，安全和风控风险更高，代码也要换成 Telethon/Pyrogram 这一类方案。

## 一键菜单安装

升级到新版项目后，执行：

```bash
x update
x local-api
```

菜单里先选：

```text
1) Install / update local Bot API server
```

按提示输入 `api_id` 和 `api_hash`。脚本会把它们保存到：

```text
/etc/telegram-bot-api.env
```

不会写进 GitHub 项目目录。

安装完成后再执行：

```bash
x local-api-switch
x 1080p
```

它会：

- 停止当前转发机器人
- 对公网 Bot API 执行一次 `logOut`
- 测试本地 `http://127.0.0.1:8081`
- 自动修改 `.env`
- 重启转发机器人

查看状态：

```bash
x local-api-status
x quality
```

如果要切回公网 Bot API：

```bash
x local-api-public
```

## 手动配置

等本地 `telegram-bot-api` 服务跑起来以后，执行：

```bash
x env
```

把下面几项改成：

```env
BOT_API_BASE_URL=http://127.0.0.1:8081
BOT_API_USE_LOCAL_FILE_URI=true
MAX_UPLOAD_MB=1900
AUTO_COMPRESS=false
DOWNLOAD_FORMAT=bv*+ba/best
UPLOAD_MODE=video
```

保存后重启：

```bash
x restart
```

再查看：

```bash
x quality
x logs
```

## 没装 Local Bot API Server 时不要这样配

如果你把 `BOT_API_BASE_URL=http://127.0.0.1:8081` 配好了，但 VPS 上没有运行 `telegram-bot-api`，机器人会连不上 Telegram API。

这时先恢复公网模式：

```env
BOT_API_BASE_URL=https://api.telegram.org
BOT_API_USE_LOCAL_FILE_URI=false
MAX_UPLOAD_MB=49
AUTO_COMPRESS=true
```

然后：

```bash
x restart
```

## 为什么不能只改 MAX_UPLOAD_MB

只把 `MAX_UPLOAD_MB=1900` 改大没用。公网 Bot API 仍然会拒绝大文件，最后常见报错就是 `Request Entity Too Large` 或上传超时。

`MAX_UPLOAD_MB` 只是本项目自己的判断线；真正的 Telegram 上传能力由你使用的是公网 Bot API 还是 Local Bot API Server 决定。

## 官方资料

- Telegram Bot API: https://core.telegram.org/bots/api
- Local Bot API Server 源码: https://github.com/tdlib/telegram-bot-api
