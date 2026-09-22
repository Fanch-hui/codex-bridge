# Codex Bridge

[简体中文](./README.md) · [English](./README_en.md)

[Published on the official MCP Registry.](https://registry.modelcontextprotocol.io/v0.1/servers/io.github.yeyuancc0-glitch%2Fcodex-bridge/versions/latest)

Codex Bridge 是面向个人自托管场景的桌面 App 与后台服务，将 ChatGPT 网页版、Qwen Studio 和本机工作台接入已授权的本地项目，并统一管理 Codex、OpenCode、DeepSeek Harness 与 Antigravity 的任务、审批和会话。

macOS 与 Windows 共用 Swift 核心和桌面界面。项目权限、任务记录与配置保存在本机；调用 ChatGPT 或模型服务时，请求会发送给你选择的服务。

当前版本为 `v1.1.2`。

## 下载与安装

从 [GitHub Releases](https://github.com/yeyuancc0-glitch/codex-bridge/releases/latest) 下载最新版本。

| 平台 | v1.1.2 安装包 | 安装方式 |
| --- | --- | --- |
| macOS 14+，Apple Silicon | `CodexBridge-1.1.2-macos-arm64.dmg` | 打开 DMG，将 App 拖入 Applications |
| Windows x64 | `CodexBridge-Windows-x64-1.1.2-Setup.exe` | 运行安装器，选择安装位置 |
| Windows x64，便携运行 | `codex-bridge-windows-x64.zip` | 完整解压后运行 `codex-bridge-windows-app.exe` |

macOS 安装包使用 ad-hoc 签名，尚未经过 Apple 公证。若系统阻止打开，请在系统设置的“隐私与安全性”中允许此次打开。Windows 需要 WebView2 Runtime；App 会在运行环境缺失时给出提示。

升级时沿用现有应用数据和内置浏览器登录态。Windows 关闭主窗口后保留托盘，使用托盘菜单退出。

带内置更新功能的版本会在每次启动时后台检查 GitHub 更新，发现新版后在首页提示。点击“立即更新”即可下载并安装；有任务正在执行时，等待任务结束后安装并重新启动。每次更新完成后请在 ChatGPT 中刷新一次插件以清除旧版缓存（参见 [配置指南](./docs/CHATGPT_DEVELOPER_MODE.md#8-版本更新后在-chatgpt-刷新插件防旧版缓存)）。设置页可手动检查更新。旧版本需先手动安装一次带更新功能的版本。

## 实际界面与任务演示

以下页面为 macOS 实录，Windows 共用同一套产品界面。约 15 秒演示：ChatGPT 提交“你好” → 本机批准 → Codex 执行 → 工作台显示回复。

<img src="./docs/assets/workbench-demo.gif" width="640" alt="ChatGPT 提交任务、本机批准与 Codex 执行回复的完整动态演示">

<details>
<summary>查看任务批准画面</summary>

本机批准卡片显示待执行操作，点击“仅本次允许”后继续执行任务。

<img src="./docs/assets/task-approval.jpg" width="640" alt="任务批准画面">

</details>

<details>
<summary>查看概览与设置页面</summary>

概览页集中显示后台服务、本地 MCP 通道、Secure Tunnel、Agent 引擎和最近任务状态。

<img src="./docs/assets/overview.png" width="640" alt="Codex Bridge 概览">

Agent 模型设置页展示 Codex、Antigravity CLI 和 DeepSeek Harness 的模型、推理强度与权限。

<img src="./docs/assets/agent-models.png" width="640" alt="Agent 模型与权限">

OpenCode 的模型与权限设置，以及 Direct 工作区的命令模式、白名单和黑名单。

<img src="./docs/assets/direct-workspace.png" width="640" alt="Direct Workspace 设置">

审批与 MCP 设置页展示 Direct 操作和远程任务启动策略，以及 GPT/Qwen 的 MCP 自定义指令。

<img src="./docs/assets/approvals.png" width="640" alt="审批与 MCP 设置">

</details>

## 使用指南

- [详细使用指南](./docs/USER_GUIDE.md)：安装、项目权限、Qwen、任务与故障排查
- [ChatGPT / Tunnel / OpenAI API Key 配置](./docs/CHATGPT_DEVELOPER_MODE.md)
- [DeepSeek Harness 安装与 API 配置](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [OpenCode 连接](./docs/OPENCODE_CONNECTION_GUIDE.md) · [Antigravity 连接与权限](./docs/ANTIGRAVITY_CONNECTION_GUIDE.md)
- [MCPB 客户端连接与 Registry 发布](./docs/MCP_REGISTRY.md)

## 首次配置

1. **启动服务**：打开 App，确认后台服务已连接。macOS 如提示后台项目需要批准，请按提示在系统设置中允许。
2. **添加项目**：登记本地目录，并设置读取、写入和网络权限。
3. **连接 Agent**：首次初始化自动扫描并保存本机 Agent；在连接页点击连接完成验证和启用。后续安装 Agent 后点击“扫描 Agent”更新目录。Codex 使用本机 Codex 执行通道；DeepSeek Harness 可在 App 中配置服务地址和 API key。
4. **选择项目和模式**：在工作台选择项目以及 `Read Only` / `Write`。
5. **连接聊天客户端**：ChatGPT 使用 OpenAI Secure MCP Tunnel（ChatGPT 需要有 Plus 及以上订阅或团队订阅才可以使用）；Qwen Studio 使用本机回环 HTTP MCP，连接页提供配置复制入口。
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

## 任务并发限制

macOS 与 Windows 使用相同的任务并发规则：

| 范围 | 限制 |
| --- | --- |
| 同一个项目 | 最多 1 个活跃写入任务，所有 Agent 共用该名额 |
| 不同项目 | 可以同时执行写入任务，仍受对应 Agent 的并发限制 |
| Codex | 最多 4 个并发执行会话，只读与写入合计 |
| 外部 Agent | Bridge 未设置统一的总并发上限；受项目写入名额、Provider 自身限制和本机资源约束 |

待本机批准、启动中、运行中、等待权限批准及状态未知的写入任务都会占用项目写入名额。达到限制时，新任务会被拒绝或启动失败，需要在名额释放后重试；不会自动排队。任务历史记录数量不计入执行并发限制。

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

## 社区

感谢 [LINUX DO](https://linux.do/) 社区。
