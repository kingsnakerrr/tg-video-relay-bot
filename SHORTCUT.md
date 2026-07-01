# iPhone 快捷指令

目标：在 iPhone 的 X/Twitter 里打开帖子，点分享，选择快捷指令，直接提交到 VPS 下载并转发到 Telegram 目标群/频道。

## VPS 配置

确认服务是新版：

```bash
x shortcut
```

它会显示：

```text
Shortcut URL:
  http://你的VPS_IP:8787/submit

Shortcut form fields:
  secret = 一串密钥
  url    = Shortcut Input URL
```

如果 iPhone 访问不到 `8787` 端口，需要在 VPS 防火墙/云服务器安全组放行 TCP `8787`，或者用 Nginx/Caddy 反代成 HTTPS。

## 创建快捷指令

1. 打开 iPhone「快捷指令」
2. 点右上角 `+`
3. 名字写：`发给视频机器人`
4. 点底部 `i`
5. 打开「在共享表单中显示」
6. 接收类型只保留 `URL`

添加动作：

1. `获取输入中的 URL`
2. `获取 URL 内容`

`获取 URL 内容` 设置：

```text
URL: http://你的VPS_IP:8787/submit
方法: POST
请求体: 表单
```

表单字段：

```text
secret = x shortcut 里显示的密钥
url = 快捷指令输入
```

可选：最后加一个「显示通知」动作，内容写：

```text
已提交给 VPS
```

## 使用

在 X/Twitter 里打开帖子：

```text
分享 -> 发给视频机器人
```

VPS 收到后会加入队列，下载并上传到 `.env` 里的 `TARGET_CHAT_IDS`。

## 测试

先在 VPS 本地测试：

```bash
x shortcut
```

复制它显示的 `Local test` 命令执行。如果返回：

```json
{"ok": true}
```

说明接口正常。

## 安全

- `SUBMIT_API_SECRET` 不要发给别人。
- 推荐用 HTTPS 反代，不推荐长期裸用 HTTP。
- 如果 secret 泄露，执行 `x env` 修改 `SUBMIT_API_SECRET`，然后 `x restart`。
