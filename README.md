# 砰！图床

自托管的 Google 团队盘图床：管理员后台与前端上传账号分离，支持拖拽/粘贴上传、图片直链、今天/本周/本月/全部统计。Google 团队盘保持私有，图片由 VPS 代理输出不可枚举的随机链接。

## 一键安装（GitHub 版）

### 安装前只准备两样东西

1. 一台 Ubuntu / Debian VPS，开放 TCP 80、443、7077、7078 端口。
2. 一个域名，例如 `img.example.com`，提前添加 A 记录指向 VPS 公网 IP。

把本项目全部文件上传到 `kingsnakerrr/tg-video-relay-bot` 仓库根目录，然后 SSH 登录 VPS，只运行这一条命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kingsnakerrr/tg-video-relay-bot/main/install.sh)
```

安装过程中只会询问一次图床域名。脚本会自动安装 Docker、拉取代码、启动前后端、配置 Caddy 并申请 HTTPS。完成后会显示：

```text
前端地址：https://img.example.com:7078/
后端地址：https://img.example.com:7077/admin
后台账号：admin
后台随机密码：自动生成的随机密码
```

先用安装结果中的 `admin` 和随机密码登录后端，完成团队盘配置，再在“后台设置 → 前端登录账号”里创建前端账号密码。没有 GitHub 私库访问凭证时请使用公开仓库；服务账号 JSON、密码和图片数据库都只产生在 VPS 的 `/opt/drivepic/data`，不会进入 GitHub。

## Google 团队盘如何对接

使用的是 Google 官方 Drive API，不是把团队盘公开分享。

### 1. 创建 API 服务账号

1. 打开 [Google Cloud Console](https://console.cloud.google.com/)，创建或选择一个项目。
2. 进入“API 和服务 → 库”，搜索并启用 **Google Drive API**。
3. 进入“IAM 和管理 → 服务账号”，创建一个服务账号，例如 `drivepic`。
4. 打开这个服务账号，进入“密钥 → 添加密钥 → 创建新密钥 → JSON”。浏览器会下载一个 JSON 文件。

Google 的官方密钥创建步骤见：[创建服务账号密钥](https://docs.cloud.google.com/iam/docs/keys-create-delete)。JSON 密钥只显示/下载一次，请妥善保存。

### 2. 把服务账号加入团队盘

1. 用文本编辑器打开刚下载的 JSON，找到 `client_email`，类似 `drivepic@项目ID.iam.gserviceaccount.com`。
2. 打开 Google Drive → 共享云端硬盘（团队盘）→ 选择目标团队盘 → 管理成员。
3. 添加这个 `client_email`，角色选择 **内容管理员**。
4. 在团队盘中新建一个专门存图的目录，例如 `drivepic-images`。

内容管理员可以上传、移动和删除文件，符合图床后台删除图片的需要。Google 官方权限说明：[团队盘成员与角色](https://support.google.com/a/users/answer/9310249?hl=zh-Hans)。

### 3. 找到两个 ID

- 团队盘 ID：打开团队盘后，地址通常类似 `https://drive.google.com/drive/u/0/folders/0Axxxxxxx`，`folders/` 后面就是团队盘 ID。
- 目标目录 ID：进入刚建的目录，地址中 `folders/` 后面就是目录 ID。

网页初始化时填写这两个 ID，再上传或粘贴完整的 JSON。系统会用 Drive API 的 `supportsAllDrives=true` 模式检查团队盘和目录并实际测试授权。Google 的团队盘 API 规范见：[Shared Drive API 支持](https://developers.google.com/workspace/drive/api/guides/enable-shareddrives)。

## 首次登录与网页配置

安装脚本会自动生成管理员，不需要自己设初始后台密码：

1. 打开后端地址 `https://img.example.com:7077/admin`。
2. 使用账号 `admin` 和安装结果中的随机密码登录；忘记时运行 `sudo drivepic credentials`。
3. 填写图床完整网址、团队盘 ID、目标目录 ID和服务账号 JSON。
4. 测试成功后进入“后台设置”，创建一个或多个前端登录账号。
5. 前端用户打开 `https://img.example.com:7078/`，使用后台创建的账号密码登录上传。

点击“测试连接并完成安装”。只有 Google API 确认团队盘和目录都能访问后才会完成初始化。

管理员后台可以更换域名、团队盘、目录、服务账号 JSON、默认链接有效期、管理员密码，以及新增、重置或删除前端账号。前端账号不能修改系统设置或删除团队盘原文件。

## VPS 管理命令

```bash
sudo drivepic status   # 查看运行状态
sudo drivepic logs     # 查看实时日志
sudo drivepic update   # 从 GitHub 拉取最新版并重建
sudo drivepic restart  # 重启
sudo drivepic credentials # 查看前后端地址与管理员凭据
sudo drivepic backup   # 备份配置、数据库和 Google 密钥
```

数据目录是 `/opt/drivepic/data`。迁移 VPS 时，先执行备份并保存生成的压缩包。

## 更新

把修改后的代码推送到 GitHub，然后在 VPS 运行：

```bash
sudo drivepic update
```

## 链接安全

图片地址形如：

```text
https://img.example.com:7078/i/<192-bit 随机令牌>/example.jpg
```

Google 文件 ID、团队盘 ID和密钥不会出现在公开链接中。知道某张链接的人能查看该图，但无法枚举其他图片；后台删除或链接到期后会立即失效。团队盘不需要设置“知道链接的任何人可查看”。

公开图床链接天然允许收件人转发。如果图片绝对不能被转发，应使用登录后访问模式，而不是公开直链。

## 常见问题

- **网页打不开**：检查域名 A 记录、VPS 防火墙和云厂商安全组的 80、443、7077、7078 端口。
- **HTTPS 申请失败**：域名必须已经解析到当前 VPS，且 80/443 未被 Nginx、宝塔等其他程序占用。
- **403 / 无法访问团队盘**：确认 JSON 中的 `client_email` 已作为团队盘成员加入，并拥有内容管理员角色。
- **找不到目录**：确认目录位于填写的团队盘内，且没有把普通“我的云端硬盘”目录 ID 填进来。
- **已有宝塔或 Nginx**：默认一键安装会占用 80/443；请先释放端口，或自行把应用的 3000 端口反代到域名。
