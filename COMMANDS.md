# 控制命令

安装完成后，VPS 上直接输入：

```bash
x
```

会出现菜单，可以选择启动、暂停、重启、日志、更新、卸载等操作。

也可以直接执行短命令：

```bash
x start       # 启动
x stop        # 暂停/停止
x pause       # 暂停/停止
x restart     # 重启
x status      # 查看状态
x logs        # 实时日志
x env         # 修改 .env 配置
x update      # 更新代码并重启
x reinstall   # 重新执行安装
x uninstall   # 卸载服务，保留 /opt/tg-video-relay-bot 和 .env
x purge       # 彻底删除服务和 /opt/tg-video-relay-bot
```

旧命令 `tg-video-relay` 也会保留，但以后记 `x` 就行。

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
