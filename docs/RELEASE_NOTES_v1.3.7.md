# Codex Bridge v1.3.7

## 主要更新

- 优化工作台内置浏览器切换：浏览器状态独立更新，减少完整页面状态传输与对话内容重复渲染，改善切换响应速度。
- 页首刷新按当前页面更新内容；首页刷新服务、项目、Agent 连接与任务状态。
- 各 Agent 的模型列表独立刷新；Codex 刷新仅更新 Codex 模型目录，模型与权限选择自动保存。
- “退出 App 后继续运行服务”改为独立开关，并明确说明 ChatGPT 插件远程使用所需的权限与自动审批配置；设置页保留服务审批和故障处理入口。
- 修复 Windows 窗口行为：最小化后保留任务栏入口，关闭主窗口后收进托盘，托盘菜单提供明确的“退出应用程序”。再次启动时唤起已有窗口，共用浏览器配置的不同安装目录也采用同一窗口。
- 工作台与设置页改进覆盖 macOS、Windows 与 Linux；任务栏和托盘修复适用于 Windows。

## 下载与安装

| 平台 | 安装包 | 便携包或更新包 |
| --- | --- | --- |
| macOS 14+ Apple Silicon | `CodexBridge-1.3.7-macos-arm64.dmg` | `CodexBridge-1.3.7-macos-arm64.zip` |
| macOS 14+ Intel | `CodexBridge-1.3.7-macos-x86_64.dmg` | `CodexBridge-1.3.7-macos-x86_64.zip` |
| Windows x64 | `CodexBridge-Windows-x64-1.3.7-Setup.exe` | `codex-bridge-windows-x64.zip` |
| Windows ARM64 | `CodexBridge-Windows-arm64-1.3.7-Setup.exe` | `codex-bridge-windows-arm64.zip` |
| Ubuntu 24.04 LTS x64 | `CodexBridge-Linux-x64-1.3.7.deb` | `codex-bridge-linux-x64-1.3.7.tar.gz` |
| Ubuntu 24.04 LTS ARM64 | `CodexBridge-Linux-arm64-1.3.7.deb` | `codex-bridge-linux-arm64-1.3.7.tar.gz` |

macOS 打开 DMG 后将 App 拖入 Applications；安装包使用 ad-hoc 签名，首次打开时按系统提示在“隐私与安全性”中允许。Windows 运行对应架构的安装器，便携包完整解压后运行 `codex-bridge-windows-app.exe`。

Linux 1.3.5 升级需要从本次 Release 手动下载对应架构的安装包。Ubuntu 使用 APT 安装 `.deb`，以同时安装运行依赖，例如：

```bash
sudo apt install ./CodexBridge-Linux-x64-1.3.7.deb
```

Linux 便携包解压后运行 `./codex-bridge`，运行依赖与数据目录见 [Linux 指南](./LINUX.md)。

## 使用提示

- 升级沿用已有项目、任务、应用数据与内置浏览器登录态。
- **更新后请在 ChatGPT 的插件设置中刷新 Codex Bridge**，让工具与模型列表生效。
- 开启“退出 App 后继续运行服务”后，即使退出 App，仍可通过 ChatGPT 的 Codex Bridge 插件远程使用本机。请配置好客户端与项目权限；需要无人值守运行时，将相关审批策略设为“自动批准”。
