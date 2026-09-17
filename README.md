# Codex Bridge

[简体中文](./README.md) · [English](./README_en.md)

Codex Bridge 是面向个人自托管场景的桌面 App 与后台服务，将 ChatGPT 网页版、Qwen Studio 和本机工作台接入已授权的本地项目，并统一管理 Codex、OpenCode、DeepSeek Harness 与 Antigravity 的任务、审批和会话。

macOS 与 Windows 共用 Swift 核心和桌面界面。项目权限、任务记录与配置保存在本机；调用 ChatGPT 或模型服务时，请求会发送给你选择的服务。

## 下载与安装

从 [GitHub Releases](https://github.com/yeyuancc0-glitch/codex-bridge/releases/latest) 下载最新版本。

| 平台 | v0.5.0 安装包 | 安装方式 |
| --- | --- | --- |
| macOS 14+，Apple Silicon | `CodexBridge-0.5.0-macos-arm64.dmg` | 打开 DMG，将 App 拖入 Applications |
| Windows x64 | `CodexBridge-Windows-x64-0.5.0-Setup.exe` | 运行安装器，选择安装位置 |
| Windows x64，便携运行 | `CodexBridge-Windows-x64-0.5.0.zip` | 完整解压后运行 `codex-bridge-windows-app.exe` |

macOS 安装包使用 ad-hoc 签名，尚未经过 Apple 公证。若系统阻止打开，请在系统设置的“隐私与安全性”中允许此次打开。Windows 需要 WebView2 Runtime；App 会在运行环境缺失时给出提示。

升级时沿用现有应用数据和内置浏览器登录态。Windows 关闭主窗口后保留托盘，使用托盘菜单退出。

## 首次配置

1. **启动服务**：打开 App，确认后台服务已连接。macOS 如提示后台项目需要批准，请按提示在系统设置中允许。
2. **添加项目**：登记本地目录，并设置读取、写入和网络权限。
3. **连接 Agent**：在连接页选择已安装的 Agent，完成发现、验证和启用。Codex 使用本机 Codex 执行通道；DeepSeek Harness 可在 App 中配置服务地址和 API key。
4. **选择项目和模式**：在工作台选择项目以及 `Read Only` / `Write`。
5. **连接聊天客户端**：ChatGPT 使用 OpenAI Secure MCP Tunnel；Qwen Studio 使用本机回环 HTTP MCP，连接页提供配置复制入口。
6. **执行任务**：在本机工作台提交，或由已连接的聊天客户端调用 `submit_task`。任务输出、工具执行、审批和结构化提问在工作台显示。

密钥通过系统凭据存储管理。分享配置、日志或截图前，请移除凭据。

## 能力

| 模块 | 功能 |
| --- | --- |
| Codex | Thread/Turn、实时输出、审批、结构化提问、补充指令与中断 |
| OpenCode | ACP 连接、模型与推理选项、权限回传、会话继续 |
| DeepSeek Harness | ACP 入口与能力探测、真实模型目录、搜索配置、MCP 服务配置与会话持久化 |
| Antigravity | CLI 接入、原生权限策略、执行过程与会话继续 |
| 工作台 | 按 Agent 分组的项目会话、历史分页、工具卡片、任务控制和审批 |
| Direct Workspace | 受控文件读写、Patch、命令执行与 Git 操作 |
| Skills | 本机技能发现、只读查看与显式 Action 调用 |

可用能力由实际 Agent、连接探测和项目权限共同决定。远程请求省略 `project_id` 时使用工作台默认项目；省略 `provider_id` 时使用 Codex。

## 架构

```text
ChatGPT Web ── Secure MCP Tunnel ─┐
Qwen Studio ── localhost MCP ────┼─► Codex Bridge Service
Desktop App ── local IPC ────────┘   ├─ 项目权限与审批
                                    ├─ 任务、会话与 SQLite
                                    ├─ Codex / OpenCode / DSH / AGY
                                    └─ Direct Workspace / Skills
```

macOS 使用 WKWebView 和 XPC；Windows 使用 WebView2 和命名管道。两平台共用 `BridgeDesktopUI` 与 `BridgeServiceAppCore`。Windows 展示采用状态版本检查、页面缓存和增量消息更新；活动会话继续通过独立订阅接收实时输出。

## 从源码构建

默认开发主线为 `win`。

```bash
git clone --branch win https://github.com/yeyuancc0-glitch/codex-bridge.git
cd codex-bridge
```

### macOS Apple Silicon

需要 Xcode 与可编译项目的 Swift 工具链。

```bash
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj -scheme CodexBridge \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

普通源码构建可使用本地 MCP。ChatGPT Secure Tunnel 还需要经过摘要校验的 `tunnel-client`；正式安装包已包含该组件。

### Windows x64

需要 Swift 6.3.3、Visual Studio C++ 工具链、Windows SDK、vcpkg SQLite，以及生成安装器所需的 Inno Setup 7.1.0。

```powershell
pwsh -File Scripts/build-windows.ps1 `
  -VcpkgRoot 'D:\Dev\Tools\vcpkg' `
  -Installer -ISCCPath 'C:\Program Files (x86)\Inno Setup 7\ISCC.exe'
```

构建脚本使用 `swiftbuild`，输出 portable ZIP 和 EXE 安装器到 `.build`。

## 许可与隐私

- [Apache-2.0 许可证](./LICENSE)
- [第三方声明](./NOTICE) · [依赖说明](./docs/DEPENDENCIES.md)
- [隐私说明](./PRIVACY.md) · [安全政策](./SECURITY.md)
