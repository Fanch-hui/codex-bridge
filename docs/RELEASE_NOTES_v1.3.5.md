# Codex Bridge v1.3.5

## 主要更新

- 新增 Windows ARM64 原生安装包与便携包，与 Windows x64 共用桌面界面、后台服务和更新流程。
- 新增 Intel Mac 原生安装包，支持 macOS 14 及以上；Apple Silicon 与 Intel 分别提供 DMG 和 ZIP。
- 新增 Ubuntu 24.04 LTS x64 与 ARM64 完整桌面版，使用 GTK 3 / WebKitGTK 4.1 承载共用的工作台、项目、连接、设置和日志页面。
- Linux 后台服务使用 Unix domain socket，按用户与安装目录验证本机连接；应用与服务数据遵循 XDG 目录规范，凭据存入系统 Secret Service。
- Linux Direct 命令支持通过 bubblewrap 隔离网络；Agent 发现、进程执行、文件与 Git 操作、Tunnel helper 已适配 Linux。
- Linux 提供 `.deb` 安装包和 `.tar.gz` 便携包，包含 Swift 运行库、共享资源与 Tunnel helper；应用内更新入口提供对应架构的安装包下载。
- Windows 与 Linux 共用桌面状态和命令适配层，三平台继续共用 Swift 核心与桌面产品界面。

## 下载与安装

| 平台 | 安装包 | 便携包或更新包 |
| --- | --- | --- |
| macOS 14+ Apple Silicon | `CodexBridge-1.3.5-macos-arm64.dmg` | `CodexBridge-1.3.5-macos-arm64.zip` |
| macOS 14+ Intel | `CodexBridge-1.3.5-macos-x86_64.dmg` | `CodexBridge-1.3.5-macos-x86_64.zip` |
| Windows x64 | `CodexBridge-Windows-x64-1.3.5-Setup.exe` | `codex-bridge-windows-x64.zip` |
| Windows ARM64 | `CodexBridge-Windows-arm64-1.3.5-Setup.exe` | `codex-bridge-windows-arm64.zip` |
| Ubuntu 24.04 LTS x64 | `CodexBridge-Linux-x64-1.3.5.deb` | `codex-bridge-linux-x64-1.3.5.tar.gz` |
| Ubuntu 24.04 LTS ARM64 | `CodexBridge-Linux-arm64-1.3.5.deb` | `codex-bridge-linux-arm64-1.3.5.tar.gz` |

macOS 打开 DMG 后将 App 拖入 Applications；安装包使用 ad-hoc 签名，首次打开时按系统提示在“隐私与安全性”中允许。Windows 运行对应架构的安装器，便携包完整解压后运行 `codex-bridge-windows-app.exe`。

Ubuntu 使用 APT 安装对应架构的 `.deb`，以同时安装运行依赖，例如：

```bash
sudo apt install ./CodexBridge-Linux-x64-1.3.5.deb
```

Linux 便携包解压后运行 `./codex-bridge`，运行依赖与数据目录见 [Linux 指南](./LINUX.md)。Linux 更新下载新版本 `.deb` 后通过系统包管理器安装，再重新启动应用。

## 使用提示

- 升级沿用已有项目、任务、应用数据与内置浏览器登录态。
- 更新后请在 ChatGPT 的插件设置中刷新 Codex Bridge，让工具与模型列表生效。
- Linux 首次使用时，按桌面会话提示解锁系统钥匙环。Direct 禁网模式需要系统允许 bubblewrap 创建网络命名空间。
- Codex、OpenCode、DeepSeek Harness、Antigravity、Pi 与 Qoder 使用本机已安装的运行时，其实际能力由连接探测和项目权限共同决定。
