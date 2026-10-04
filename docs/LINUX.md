# Linux 桌面版

支持 Ubuntu 24.04 LTS 的 x64 与 ARM64。桌面使用 GTK 3 与 WebKitGTK，工作台、项目、连接、设置和日志页面与 macOS、Windows 共用。

## 安装

选择与系统架构一致的 `.deb`，使用 APT 安装，以同时安装运行依赖：

```bash
sudo apt install ./CodexBridge-Linux-x64-*.deb
```

ARM64 使用文件名中的 `arm64` 包。安装后从应用菜单打开 Codex Bridge。

便携包解压后运行目录内的 `./codex-bridge`。便携运行同样需要 GTK 3、WebKitGTK 4.1、SQLite、Secret Service 和 bubblewrap；Swift 运行库随包提供。

## 本机数据与服务

- 服务数据：`$XDG_DATA_HOME/CodexBridgeService`，默认 `~/.local/share/CodexBridgeService`。
- 桌面与浏览器数据：遵循 XDG 用户数据目录。
- 本机通信：`$XDG_RUNTIME_DIR/CodexBridge/service.sock`，限同一用户及同安装目录的桌面程序访问。
- 密钥：存入桌面会话的 Secret Service（Ubuntu 默认使用 GNOME Keyring）。首次使用时按系统提示解锁钥匙环。
- Linux 更新由系统包管理器完成；应用内更新入口提供新版本下载。

`.deb` 升级前会检查已安装服务的 Agent 任务、Direct 命令与工作区操作。有活动任务时拒绝升级，待任务完成后重试；空闲服务停止并实际退出后才替换文件。旧服务若不支持空闲检查，请先完成任务、退出 App 并停止后台服务，再重试安装。

Direct 命令的禁网模式使用 bubblewrap 创建独立网络命名空间。系统未提供所需隔离能力时，该模式会返回明确错误。

## 从源码构建

需要 Swift 6.3.3、Node.js 22 和以下系统依赖：

```bash
sudo apt install build-essential pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev \
  libsqlite3-dev libsecret-tools gnome-keyring bubblewrap dbus-x11 python3 unzip curl
Scripts/build-linux.sh
```

脚本使用 `swiftbuild` 编译当前机器架构，产物位于 `.build/linux-dist`，包括 `.deb` 与 `.tar.gz`。CI 分别使用 Ubuntu 24.04 x64 和 ARM64 原生 runner。
