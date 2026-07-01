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
x test-submit "https://x.com/..." # 从 VPS 本地测试提交
x logs        # 实时日志
x cookies     # 立即同步 cookies.txt
x shortcut    # 查看 iPhone 快捷指令配置
x env         # 修改 .env 配置
x update      # 更新代码并重启
x reinstall   # 重新执行安装
x uninstall   # 卸载服务，保留 /opt/tg-video-relay-bot 和 .env
x purge       # 彻底删除服务和 /opt/tg-video-relay-bot
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
