# Codex Bridge 详细使用指南

适用于 v0.5.0 的 macOS Apple Silicon 和 Windows x64。首次使用按“安装 → 项目 → Agent → 模型 → 聊天客户端 → 第一项任务”的顺序操作。

## 文档导航

- [ChatGPT、Tunnel 与 OpenAI Runtime API Key](./CHATGPT_DEVELOPER_MODE.md)
- [DeepSeek Harness 安装、API Key、连接与模型](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [OpenCode 安装与连接](./OPENCODE_CONNECTION_GUIDE.md)
- [Antigravity 安装、连接与权限](./ANTIGRAVITY_CONNECTION_GUIDE.md)

## 1. 客户端与 Agent

ChatGPT、Qwen Studio 和 Bridge 工作台是提交任务的入口。Codex、OpenCode、DeepSeek Harness（DSH）和 Antigravity（AGY）是实际执行任务的本机 Agent。

```text
ChatGPT ── Secure MCP Tunnel ─┐
Qwen ──── 本机 HTTP MCP ──────┼─ Bridge Service ─ 项目 / Agent / 审批 / 会话
Bridge 工作台 ── 本机 IPC ────┘
```

你可以先只用本机工作台，再配置 ChatGPT 或 Qwen。远程请求省略 `provider_id` 时使用 Codex；使用其他 Agent 时要明确选择。

## 2. 安装与启动

### macOS Apple Silicon

1. 从 [最新版下载页](https://github.com/yeyuancc0-glitch/codex-bridge/releases/latest) 下载 `CodexBridge-0.5.0-macos-arm64.dmg`。
2. 打开 DMG，把 `CodexBridge.app` 拖到 Applications。
3. 从 Applications 启动。当前包使用 ad-hoc 签名、尚未 Apple 公证；若系统拦截，在“系统设置 → 隐私与安全性”允许打开。
4. 在概览检查 Service。若提示后台项目需批准，按提示打开系统设置并允许 Codex Bridge 后台项目。
5. 回到 App 刷新状态，确认 Service 和本地 MCP 可用。

### Windows x64

1. 下载 `CodexBridge-Windows-x64-0.5.0-Setup.exe`。
2. 运行安装器，选择安装目录，完成后启动 Codex Bridge。
3. 如提示缺少 WebView2 Runtime，按提示安装微软 WebView2 Runtime，然后重新启动 App。
4. 在概览确认 Service 和本地 MCP 可用。

便携版下载 `codex-bridge-windows-x64.zip`，完整解压后运行目录内的 `codex-bridge-windows-app.exe`。保留旁边的服务、DLL、资源目录和 Helper。

Windows 关闭主窗口会隐藏到托盘；需要退出时使用托盘菜单。升级时保留现有应用数据和浏览器登录态。

## 3. 页面导航

| 页面 | 主要用途 |
| --- | --- |
| 概览 | 检查 Service、本地 MCP 和 Tunnel 状态 |
| 工作台 | 选择项目/Agent/会话、提交任务、查看输出与审批 |
| 项目 | 登记本地目录，配置项目访问与执行策略 |
| 连接 | 连接 Agent、配置 Tunnel、复制 Qwen 配置、管理 DSH MCP |
| 设置 | 模型与推理选项、后台偏好、Direct 设置、MCP 自定义指令 |
| 日志 | 排查连接与任务故障 |

## 4. 添加项目与权限

1. 打开“项目”，点击添加项目并选择项目根目录。
2. 在项目详情中设置读取、写入和网络策略，保存。
3. 回到工作台，选择刚登记的项目。
4. 首次尝试选择 `Read Only`；需要修改代码时再选择 `Write`，同时确保项目允许写入。

| 设置 | 作用 |
| --- | --- |
| 项目读取/写入策略 | 限制该项目可接受的访问与任务模式 |
| 工作台 `Read Only` / `Write` | 新任务的默认模式 |
| 网络策略和任务网络请求 | 控制请求准入及相关网络能力 |
| Agent 原生权限 | 控制 Agent 自己的工具执行 |
| 启动审批 | 确认是否启动远程提交的任务 |

工作台所选项目是远程客户端省略 `project_id` 时的默认项目。项目禁止写入时，切换 `Write` 不能越过限制。外部 Agent 仍使用其原生 sandbox/权限机制；项目策略不代表额外的进程级网络防火墙。

远程客户端要指定项目时，应先调用 `list_projects`，使用返回的 ID，不能把显示名称当成 ID。

### Agent 权限独立

Codex 的访问模式只用于 Codex。OpenCode、DSH 和 Antigravity 分别使用自己的执行模式与原生工具权限，不从 Codex 的 `full-access` 或 `auto-review` 推导自动批准。项目策略、工作台本次任务的 Read Only / Write 和远程启动批准是共同的任务约束。

AGY 的 Always Proceed 由 AGY 连接流程单独征得同意后设置；它属于 AGY 当前系统用户的全局配置，会影响复用该配置的 AGY 实例。

本节权限隔离修复适用于包含该修复的后续构建；已发布 v0.5.0 安装包仍对应原始发布提交。

## 5. 连接 Agent

### Codex

1. 准备当前系统用户能够运行并已完成登录的本机 Codex。
2. 在“连接 → Codex 执行引擎”点击“连接”。Bridge 自动管理 Codex 发现，无需在页面选择路径或配置文件；连接失败时先查看卡片的错误信息并确认本机 Codex 可用。
3. 打开设置中的 Codex 模型区域，获取模型，选择默认模型和推理强度，保存模型偏好。
4. 回到工作台选择项目，提交只读任务。

Windows 可发现商店版及受支持的 CLI 安装位置；外部 Agent 应连接 CLI 入口。只有安装了 GUI 应用，并不代表存在可供 Bridge 调用的 Agent 协议入口。

### DeepSeek Harness

按 [DSH 详细指南](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) 安装 CLI，获取 DeepSeek 或兼容服务的 API Key，然后在 Bridge 的 DSH 连接卡片填写 Base URL 和 API Key。连接成功后获取真实模型目录，选择默认模型和该模型支持的推理强度。

### OpenCode 与 Antigravity

- [OpenCode](./OPENCODE_CONNECTION_GUIDE.md)：先安装 CLI 并完成模型服务登录，再在 Bridge 连接。
- [Antigravity](./ANTIGRAVITY_CONNECTION_GUIDE.md)：先安装并登录 CLI，在 Bridge 连接时阅读并确认无头执行权限说明。

Bridge 调用的是协议执行入口：Codex app-server、OpenCode ACP、DSH 的 Node ACP 入口和 AGY headless CLI。使用这些入口可以复用同一 Agent 的原生用户配置，不代表必须另建一套账号配置。OpenCode Desktop/CLI 的标准配置与认证通常共享；Antigravity 2.0/CLI 的核心偏好、权限和安全设置共享，具体边界见对应指南。

Bridge 自动发现安装，点击连接后才会登记并启用。安装卡片的“可用”表示连接探测通过；第一项真实任务还会验证所用账号、模型和项目是否可执行。

## 6. 模型与推理强度

1. 在设置中找到目标 Agent 的模型区域。
2. 点击“获取模型”或“刷新模型列表”。
3. 选择实际返回的模型 ID。
4. 等待该模型的能力加载，再选择页面提供的推理强度。
5. 按当前区域的保存按钮或“选择后自动保存”提示完成设置。

切换模型后，可选推理强度可能变化。DSH 模型目录来自配置服务的真实 `/models` 响应；接口失败时先解决连接问题。模型 Key、服务地址与套餐应相互匹配。

## 7. 连接 ChatGPT

完整分步说明见 [Tunnel 配置指南](./CHATGPT_DEVELOPER_MODE.md)，包含平台入口、权限和 Key 获取步骤。

流程是：在 OpenAI Platform 创建 Tunnel 和受限 Runtime Key，在 Bridge 连接页保存并等待 `ready`，再在 ChatGPT 中创建 Tunnel 类型 App。Bridge 和 ChatGPT 使用同一个 Tunnel ID。

OpenAI Runtime Key 用于 Tunnel，DeepSeek Key 用于 DSH 模型；两者分别填写。Runtime Key 不填入 ChatGPT 对话或 Qwen 配置。

## 8. 连接 Qwen Studio

1. 启动与 Bridge 位于同一台电脑、能够访问本机回环 HTTP 的 Qwen 客户端。
2. 在 Bridge“连接 → 本地 MCP 客户端”找到 Qwen，启用该客户端。
3. 点击“复制 Qwen JSON 配置”。
4. 在 Qwen 的 MCP 服务配置中粘贴 JSON 并保存，然后连接/刷新工具。
5. 新建对话，要求调用 `bridge_status` 和 `list_projects` 检查连接。

配置由 App 生成，包括实际端口和客户端凭据。不要手工猜值。云端执行 MCP 的客户端无法通过它自己的 `127.0.0.1` 访问你的电脑。

“重新生成凭证”会使旧凭据失效，之后重新复制配置到 Qwen。“重新生成 Endpoint”会改变本机服务地址，需要更新使用旧地址的客户端。

## 9. 提交第一项任务

### 从本机工作台

1. 选择项目、Agent 和 `Read Only`。
2. 在任务输入区填写：“阅读当前项目 README，说明项目用途，不修改文件。”
3. 提交并观察会话输出。
4. 出现 Agent 工具权限请求或结构化问题时，在工作台处理。

本机工作台通过可信本地入口提交；远程任务启动审批是另一条流程。

### 从 ChatGPT 或 Qwen

在已启用 Bridge 的对话中输入：

```text
请通过 Codex Bridge 使用 DeepSeek Harness，读取当前项目 README 并总结用途，不修改文件。
```

客户端应先发现项目和 Agent，再提交相应任务，例如：

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "读取当前项目 README 并总结用途，不修改文件。",
  "network_access": false
}
```

项目和模型默认值沿用 App 设置。需要调用搜索或其他网络工具时，在任务中明确要求联网。

默认远程任务需在 Bridge 工作台批准启动。设置中的自动批准远程启动仅影响启动环节；Agent 工具审批和 Direct 操作权限各自生效。

## 10. 输出、审批、继续与中断

| 看到的状态 | 操作 |
| --- | --- |
| 等待启动批准 | 核对项目、Agent、权限和任务后批准或拒绝 |
| 运行中 | 查看实时输出与过程卡片 |
| 等待工具审批 | 展开命令、路径和理由，选择本次提供的允许范围或拒绝 |
| 结构化问题 | 按表单回答后提交 |
| 已完成 | 查看最终回复、变更文件及本地结果 |
| 失败 | 查看错误摘要、失败码和相关日志 |
| 已中断 | 按需要继续会话或提交新任务 |

客户端通过 `get_task` 的状态和 `wait_policy` 等待结果；暂时没有文本不等于失败。单个工具失败会保留在过程记录中，整项任务结果以最终状态为准。

工作台可发送补充指令或中断任务。具体操作服从当前 Agent 的能力；历史续聊选择原项目、原 Agent 安装对应的会话，DSH 的恢复取决于握手能力和已保存会话。模型与安装变化后，先查看连接状态再继续。

## 11. Direct 与 Skills

Direct 让聊天客户端直接执行授权的文件、命令或 Git 操作，不通过 Agent 生成执行计划。

1. 在设置中管理 Direct 执行模式与规则。
2. 在项目中设置访问策略和需要的 workspace commands。
3. 命令使用可执行文件与结构化参数；按需要设置允许项和黑名单。
4. 写入、命令与 Git 请求按实际策略进入批准流程。

Skills 区域显示本机发现的技能，可查看内容。需要执行时，由客户端使用实际发现的 Skill 和 Action；页面没有编辑接口。

## 12. 日常使用与排查

| 现象 | 优先检查 |
| --- | --- |
| App 连不上 Service | 概览中的启动/注册提示；macOS 后台项目授权；Windows 同目录服务文件 |
| 本地 MCP 端口不可用 | 连接页状态；确需变更时生成新 Endpoint 并更新客户端配置 |
| Agent 未发现 | CLI 是否安装；重新打开 App，或通过高级路径登记实际入口 |
| Agent 需复核 | 确认更新来源后重新 Probe，查看不可用原因 |
| 模型获取失败 | API Key、Base URL、账号能力和网络；查看对应 Agent 指南 |
| 任务写入被拒绝 | 项目策略、工作台模式和 Agent 原生权限 |
| 项目忙碌 | 等待该项目当前写任务结束后再提交 |
| ChatGPT 连不上 | 按 Tunnel 指南检查两端状态、Workspace、Key 权限 |
| Qwen 连不上 | 本机运行位置、客户端启用状态和最新复制的 JSON |
| 任务等待且不输出 | 查看启动审批、工具审批或问题表单 |

日志用于定位具体错误。分享问题时提供系统、App 版本、操作步骤和脱敏错误摘要。密钥保存在系统凭据存储中，配置 JSON 也可能含凭据，请勿公开。
