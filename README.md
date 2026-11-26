# 一炁输入法（YiQi）

「一气化三清」——一套覆盖 **macOS、Windows、Linux、Android、iOS** 五大平台的中文拼音输入法，开箱即用，无需折腾 Rime 配置。

## 特性

- **雾凇拼音词库**：内置 [rime-ice](https://github.com/iDvel/rime-ice) 词库与预编译数据，安装即用。
- **小鹤双拼 / 全拼随时切换**：同时支持界面点击与自定义快捷键（默认 `Ctrl + Shift + 1`），适合个人使用与共用电脑场景。
- **跨设备加密剪贴板同步**：支持通过自建中转服务器跨网络同步最新一条文本（最大 1 MB），端到端 AES-256-GCM 加密，中转服务器仅见密文；手机端可在候选栏直接点选粘贴，各端均兼容常规粘贴。
- **在线检查更新**：客户端支持检测 GitHub Releases 新版本并一键更新。

---

## 使用指南

### 1. 安装与启用

前往 [GitHub Releases](https://github.com/Arthur-Null/YiQi/releases) 下载对应平台的安装包：

| 平台 | 安装包 | 安装与启用方式 |
| --- | --- | --- |
| **macOS** | `YiQi-macOS.pkg` | 双击安装后，在「系统设置 → 键盘 → 输入法」中添加「一炁输入法」；顶部菜单栏图标可切换方案与打开设置。 |
| **Windows** | `YiQi-Windows-Setup.exe` | 运行安装向导完成安装；系统托盘图标可快速切换双拼/全拼、配置同步与快捷键。 |
| **Linux** | `YiQi-Linux-amd64.deb` / `YiQi-Linux-x86_64.tar.gz` | Debian/Ubuntu 直接执行 `sudo apt install ./YiQi-Linux-amd64.deb`；其他发行版解压 `.tar.gz` 后运行 `./install.sh`（支持 Fcitx5 与 IBus，建议安装 `fcitx5-rime` 与 `librime-plugin-lua`）。 |
| **Android** | `YiQi-Android.apk` | 安装后按首页两步引导启用并选用「一炁输入法」；点击键盘左上角齿轮可进入设置与在线更新。 |
| **iOS** | `YiQi-iOS.ipa` | 通过 Xcode、AltStore、SideStore 或 TrollStore 签名安装，在「设置 → 通用 → 键盘」中添加「一炁输入法」；如需剪贴板同步请开启「允许完全访问」。 |

### 2. 切换小鹤双拼与全拼

- **桌面端（macOS / Windows / Linux）**：点击状态栏/托盘菜单直接切换，或按快捷键（默认 `Ctrl + Shift + 1`，可在设置窗口中自定义）。
- **手机端（Android / iOS）**：点击键盘工具栏右上角的 `双` / `全` 图标即时切换，空格键同步显示当前方案。

### 3. 配置跨设备剪贴板同步

剪贴板同步依赖你自己的公网中转服务（支持在客户端自由填写服务器地址）：

#### 第一步：部署中转服务

准备一台可 SSH 登录的 Linux 服务器，在本项目根目录运行：

```bash
./server/deploy.sh <ssh主机> <本机端口>
# 示例：./server/deploy.sh root@example.com 40566
```

- 服务会以 systemd（`yiqi-relay.service`）运行，并仅监听 `127.0.0.1:<端口>`。
- 使用 Nginx、Caddy 或 Cloudflare Tunnel 等将你的 HTTPS 域名反向代理至该端口（需支持 WebSocket 转发）。
- 首次部署完成时，脚本会自动输出一个 **10 分钟内有效的一次性注册临时密码**。如果已过期，可在服务器上重新生成：

```bash
/usr/local/bin/yiqi-relay code --data /var/lib/yiqi-relay
```

#### 第二步：设备配对

1. **第一台设备**：打开一炁设置 → 剪贴板同步，填入你的服务器地址（如 `https://clip.example.com`）和上一步生成的临时密码，完成同步组创建。
2. **后续设备**：在已配对设备的设置中点击「添加设备」获取邀请码，在新设备上输入同样的服务器地址与邀请码即可加入。
3. **重置同步组**：若所有已配对设备都已丢失，可在服务器上运行以下命令清空同步组后再重新注册：

```bash
/usr/local/bin/yiqi-relay reset --data /var/lib/yiqi-relay
```

### 4. 在线更新

在各端设置界面点击「检查更新」，检测到新版本后按提示完成升级；升级会自动保留你的同步配置与用户词库。

---

## 开发指南

### 目录结构

```text
.
├── rime/               # 雾凇拼音补丁（qi_patch.yaml）与双拼/全拼切换脚本（lua/qi_switch.lua）
├── scripts/            # 词库拉取打包脚本（rime_data.sh）与发布脚本（release.sh）
├── sync/               # Go 模块：加密协议（protocol）、中转服务（relay、cmd/yiqi-relay）、客户端核心（client）
├── server/             # 中转服务一键部署脚本（deploy.sh）与 systemd 配置
├── macos/              # macOS 伴侣应用（Swift）与鼠须管输入法打包脚本
├── windows/            # Windows 托盘与设置程序（Go）、小狼毫集成及 NSIS 安装包配置
├── linux/              # Linux 守护进程（Go）、GTK3 设置/托盘界面（C）、Fcitx5 主题与安装脚本
├── android/            # 同文输入法（Trime）定制补丁（patch.py）、主题（theme/）与覆盖源码（overlay/）
├── ios/                # iOS 主应用与键盘扩展（SwiftUI / UIKit + librime-static.xcframework）
├── tests/              # Rime 切换测试与 macOS 集成测试
├── VERSION             # 当前版本号（各端构建脚本统一读取）
└── .github/workflows/  # GitHub Actions 自动构建与发布流水线（build.yml）
```

### 核心实现概览

- **输入法内核与方案切换**：`scripts/rime_data.sh` 拉取固定版本的 `rime-ice`，并将 `rime/qi_patch.yaml` 与 `rime/lua/qi_switch.lua` 注入词库。各端界面与快捷键通过用户数据目录下的 `qi_schema.txt`（当前方案）和 `qi_hotkey.txt`（自定义快捷键）保持一致。
- **剪贴板同步协议**：`sync/protocol` 使用 32 字节配对密钥分别派生加密密钥与认证令牌（HMAC-SHA256），正文采用 AES-256-GCM 加密，服务器仅保存认证摘要与密文帧。Windows / Linux 复用 `sync/client`，macOS / Android / iOS 实现了同一套协议。
- **Android 定制方式**：`android/build.sh` 每次都会拉取固定 tag 的 Trime 源码并执行 `android/patch.py` 与 `android/overlay/` 覆盖。**请不要直接修改 `build/android/trime/` 下的临时文件**，所有持久化改动都应写入 `android/patch.py`、`android/theme/` 或 `android/overlay/`。

### 本地构建

> 所有构建产物均输出至 `dist/` 目录，版本号统一读取根目录的 `VERSION`。

- **macOS**（需 Xcode Command Line Tools、`librime`）：
  ```bash
  ./macos/build.sh
  # 产物：dist/YiQi-macOS.pkg
  ```
- **Windows**（Windows 下需 Go、7-Zip、NSIS；Linux 下可交叉构建）：
  ```powershell
  # Windows (PowerShell)
  ./windows/build.ps1
  ```
  ```bash
  # Linux 交叉构建（需 go、7z、makensis、rsync）
  ./windows/build.sh
  # 产物：dist/YiQi-Windows-Setup.exe
  ```
- **Linux**（需 Go、`libgtk-3-dev`、`pkg-config`、`librime-dev`、`rsync`，打包 `.deb` 另需 `dpkg-dev`）：
  ```bash
  ./linux/build.sh x86_64   # 或 arm64
  # 产物：dist/YiQi-Linux-x86_64.tar.gz、dist/YiQi-Linux-amd64.deb
  ```
- **Android**（需 JDK 21、Android SDK、`librime`）：
  ```bash
  ./android/build.sh
  # 产物：dist/YiQi-Android.apk
  ```
- **iOS**（需 macOS + Xcode + `xcodegen`，可选 `librime` 预编译词库）：
  ```bash
  ./ios/build.sh
  # 产物：dist/YiQi-iOS.ipa（未签名，可导入 Xcode 或侧载工具签名安装）
  ```
- **中转服务端**：
  ```bash
  cd sync && go build -o ../build/yiqi-relay ./cmd/yiqi-relay
  ```

### 运行测试

```bash
# 同步协议、中转与客户端核心
(cd sync && go test ./...)

# Windows / Linux 快捷键逻辑
(cd windows/app && go test ./...)
(cd linux/app && go test ./...)

# Rime 双拼 / 全拼切换测试（需安装 librime）
python3 tests/rime/test_switch.py
```

### 发布新版本

1. 修改根目录 [VERSION](VERSION)。
2. 推送 `v<版本号>` 标签以触发 `.github/workflows/build.yml` 自动构建 Windows / Linux / iOS 产物并上传至 GitHub Release；或本地执行：
   ```bash
   ./scripts/release.sh <发布说明文件>
   ```

---

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。
