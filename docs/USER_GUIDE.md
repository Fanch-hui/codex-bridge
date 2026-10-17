# Codex Bridge 详细使用指南

适用于 macOS 14+ Apple Silicon / Intel、Windows x64 / ARM64，以及 Ubuntu 24.04 LTS x64 / ARM64。首次使用按需要选择配置流程：

- **本地读写文件、运行命令**：安装并启动 Bridge → 登记项目目录 → 完成所选聊天客户端的 MCP 接入 → 在对话中启用 Codex Bridge → 直接操作项目。无需安装或连接 Agent，也无需配置 Agent 模型。
- **委派 Agent 任务**：安装并启动 Bridge → 登记项目目录 → 连接 Agent → 配置模型 → 从工作台或已连接的聊天客户端提交任务。

ChatGPT / Dot 使用 Secure MCP Tunnel；Qwen Studio 使用本机 HTTP MCP；Gemini 本地 MCP 用于与 Bridge 位于同一台电脑、能启动本机程序的 Gemini 桌面 App。**Gemini 网页版（包括 Bridge 内置浏览器）必须使用 Cloud MCP，选择 Sites 或 ngrok。** 按所用客户端选择对应流程即可。

**只使用 Gemini 时，无需配置 OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key，也无需启用 ChatGPT 的 Tunnel 连接。** 选择 Sites 仅需具备 ChatGPT Sites 的托管使用权限；本地 MCP 和 ngrok 无需使用 Sites。若要委派 Agent 任务，所选 Agent 自身的登录或 API 配置另行完成。

## 文档导航

- [ChatGPT、Tunnel 与 OpenAI Runtime API Key](./CHATGPT_DEVELOPER_MODE.md)
- [Gemini 本地 MCP](#81-连接-gemini-本地-mcp) · [Gemini 云 MCP：Sites / ngrok](#82-连接-gemini-云-mcp)
- [DeepSeek Harness ACP 安装、API Key、连接与模型](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) · [原生桌面连接](./DSH_NATIVE_DESKTOP_GUIDE.md)
- [Pi 与 Qoder 安装、地区选择与连接](./PI_QODER_CONNECTION_GUIDE.md)
- [OpenCode 安装与连接](./OPENCODE_CONNECTION_GUIDE.md)
- [Antigravity 安装、连接与权限](./ANTIGRAVITY_CONNECTION_GUIDE.md)

## 1. 客户端与 Agent

ChatGPT、Qwen Studio 和 Gemini 可以通过 Bridge 直接读写文件、运行命令，也可以委派 Agent 任务；Bridge 工作台用于提交和管理 Agent 任务。直接操作由本机 Bridge 服务的 Direct Workspace 执行。Codex、OpenCode、DeepSeek Harness（DSH）、Antigravity（AGY）、Pi 和 Qoder 是实际执行委派任务的本机 Agent。

```text
ChatGPT ── Secure MCP Tunnel ──────────┐
Qwen ──── 本机 HTTP MCP ───────────────┤
Gemini ── 本地 stdio / Sites / ngrok ──┼─ Bridge Service ─ 项目 / Agent / 审批 / 会话
Bridge 工作台 ── 本机 IPC ─────────────┘
```

委派 Agent 任务时，你可以先只用本机工作台，再配置 ChatGPT、Qwen 或 Gemini。远程任务请求省略 `provider_id` 时使用 Codex；使用其他 Agent 时要明确选择。

## 2. 安装与启动

### macOS Apple Silicon / Intel

1. 从 [最新版下载页](https://github.com/Fanch-hui/codex-bridge/releases/latest) 下载对应架构的 DMG：Apple Silicon 使用 `CodexBridge-<版本>-macos-arm64.dmg`，Intel 使用 `CodexBridge-<版本>-macos-x86_64.dmg`。
2. 打开 DMG，把 `CodexBridge.app` 拖到 Applications。
3. 从 Applications 启动。当前包使用 ad-hoc 签名、尚未 Apple 公证；若系统拦截，在“系统设置 → 隐私与安全性”允许打开。
4. 在概览检查 Service。若提示后台项目需批准，按提示打开系统设置并允许 Codex Bridge 后台项目。
5. 回到 App 刷新状态，确认 Service 和本地 MCP 可用。

### Windows x64 / ARM64

1. 下载对应系统架构的 `CodexBridge-Windows-x64-<版本>-Setup.exe` 或 `CodexBridge-Windows-arm64-<版本>-Setup.exe`。
2. 运行安装器，选择安装目录，完成后启动 Codex Bridge。
3. 如提示缺少 WebView2 Runtime，按提示安装微软 WebView2 Runtime，然后重新启动 App。
4. 在概览确认 Service 和本地 MCP 可用。

便携版下载 `codex-bridge-windows-x64.zip` 或 `codex-bridge-windows-arm64.zip`，完整解压后运行目录内的 `codex-bridge-windows-app.exe`。保留旁边的服务、DLL、资源目录和 Helper。

Windows 关闭主窗口会隐藏到托盘；需要退出时使用托盘菜单。升级时保留现有应用数据和浏览器登录态。

### Ubuntu 24.04 LTS x64 / ARM64

按[Linux 安装指南](./LINUX.md)选择对应架构的 `.deb` 并通过 APT 安装，或完整解压便携 `.tar.gz` 后运行 `./codex-bridge`。启动后在概览确认 Service 和本地 MCP 可用。升级通过系统包管理器完成。

## 3. 页面导航

| 页面 | 主要用途 |
| --- | --- |
| 概览 | 检查 Service、本地 MCP 和 Tunnel 状态 |
| 工作台 | 选择项目/Agent/会话、提交任务、查看输出与审批 |
| 项目 | 登记并授权本地目录，配置工作区命令 |
| 连接 | 连接 Agent、配置 ChatGPT Tunnel、Qwen 或 Gemini MCP、管理 DSH MCP |
| 设置 | 模型与推理选项、后台偏好、Direct 设置、MCP 自定义指令 |
| 日志 | 排查连接与任务故障 |

## 4. 登记项目与选择任务权限

1. 打开“项目”，点击添加项目并选择项目根目录。登记即授权该目录完整访问。
2. 回到工作台，选择刚登记的项目和 Agent。
3. 用户为任务选择“只读”或“完整”：只读不允许写入和工具联网；完整包含写入和联网。
4. ChatGPT/Qwen 新任务统一使用工作台的默认任务权限，客户端提交任务时不选择或覆盖权限。

| 设置 | 作用 |
| --- | --- |
| 登记项目 | 授权访问哪些目录；路径身份与目录边界持续校验 |
| 任务只读 / 完整 | 用户决定本次任务的写入与工具联网能力 |
| 工作台 Agent 权限 | 用户决定 ChatGPT/Qwen 提交新任务的默认任务权限 |
| Agent 原生审批模式 | 决定执行中哪些操作需要询问 |
| 启动审批 | 确认是否启动远程提交的任务 |

工作台所选项目是远程客户端省略 `project_id` 时的默认项目。远程客户端要指定项目时，应先调用 `list_projects`，使用返回的 ID，不能把显示名称当成 ID。

### 任务权限与原生审批

Codex 的请求审批、自动审查与完全访问独立于任务权限。选择完全访问时使用原生免审批策略 `never`；只读任务仍保持只读、工具禁网限制。

OpenCode 只读任务使用原生权限配置，仅开放读取、文件匹配、搜索和问题工具。Pi/Qoder 通过受控工具约束只读任务，这属于应用层权限，不等同于操作系统级隔离。DSH 和 Antigravity 当前执行入口不能保证任务级工具禁网，因此只读任务明确返回不支持；需要只读时选择支持该能力的 Agent。

完整任务仍服从对应 Agent 的原生审批与工具规则。Codex 的完全访问或自动审查不会改变其他 Agent 的配置。AGY 的 Always Proceed 由连接流程单独征得同意后设置；它属于当前系统用户的全局配置，会影响复用该配置的 AGY 实例。

## 5. 连接 Agent

本节用于委派 Agent 任务，所选 Agent 自身的登录或 API 配置与聊天客户端的 MCP 接入分别管理。只需要本地文件读写和命令执行时，可直接前往第 7 节连接 ChatGPT、第 8 节连接 Qwen，或第 8.1 / 8.2 节连接 Gemini，再按第 11 节使用 Direct。

### Codex

1. 准备当前系统用户能够运行并已完成登录的本机 Codex。
2. 在“连接 → Agent 引擎 → Codex”点击“连接”。Bridge 自动发现 Codex，通常无需手工指定路径；页面显示“当前使用”的实际可执行文件。连接或模型列表失败时，先查看卡片中的错误信息：如果 Codex 装在非常规位置，在“可执行文件路径（可选）”中填写 `codex`（Windows 为 `codex.exe` 或 npm 的 `codex.cmd`）的绝对路径并保存，清除该字段即恢复自动发现。路径可直接从资源管理器复制粘贴（含引号的“复制为路径”会自动去掉引号）；保存被拒绝或模型目录仍失败时，卡片与提示会给出具体原因和 Bridge 实际尝试启动的可执行文件。
3. 打开“设置 → Agent → Codex”，获取模型并选择默认模型和推理强度，选择会自动保存。
4. 在工作台选择项目和只读权限，再通过已连接的 ChatGPT 或 Qwen 提交任务。

Bridge 在每次启动 Codex 时按当前系统信息重新发现，安装 Codex 之后不需要重启 App 或后台服务；临时排障仍可用 `CODEX_BRIDGE_CODEX_EXECUTABLE` 覆盖。Windows 可发现商店版及受支持的 CLI 安装位置；外部 Agent 应连接 CLI 入口。只有安装了 GUI 应用，并不代表存在可供 Bridge 调用的 Agent 协议入口。

### DeepSeek Harness

DSH 提供两种连接方式，已有连接默认使用 ACP：

- **ACP**：按[ACP 指南](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)安装 CLI，或使用 Desktop 附带 CLI，在 DSH 连接卡片填写 Base URL 和 API Key。任务使用独立的 Bridge 配置档案；一键配置准备的也是 ACP。
- **原生桌面**：按[原生桌面指南](./DSH_NATIVE_DESKTOP_GUIDE.md)显式选择连接模式，安装 Connector 并配对，复用 Desktop 登录、工具和原生会话。首版支持 macOS、Windows x64 的完整权限文本任务，派发时 Desktop Host 必须运行。模型和推理强度选择会同步到 DSH 桌面默认，影响后续新建会话。

连接成功后刷新对应模式的模型目录，选择默认模型和该模型支持的推理选项；ACP 与原生桌面偏好分别保存。

### OpenCode 与 Antigravity

- [OpenCode](./OPENCODE_CONNECTION_GUIDE.md)：先安装 CLI 并完成模型服务登录，再在 Bridge 连接。
- [Antigravity](./ANTIGRAVITY_CONNECTION_GUIDE.md)：先安装并登录 CLI，在 Bridge 连接时阅读并确认无头执行权限说明。

### Pi 与 Qoder

按[Pi 与 Qoder 指南](./PI_QODER_CONNECTION_GUIDE.md)安装或一键配置，并完成原生登录或模型服务配置。Qoder 先选择中国版或国际版，两者分别保存登录态和模型偏好；官方目前未提供 Windows ARM64 运行时。两者接入原生会话目录，可在注册项目中浏览和续写已有会话。

Bridge 使用 Codex app-server、OpenCode ACP、DSH ACP 或原生 Desktop Connector、AGY headless CLI、Pi RPC 和 Qoder SDK 执行任务。OpenCode Desktop/CLI 的标准配置与认证通常共享；Antigravity 2.0/CLI 的核心偏好、权限和安全设置共享，具体边界见对应指南。DSH 的 ACP 配置与原生桌面配置分别管理。

Bridge 自动发现安装，点击连接后才会登记并启用。安装卡片的“可用”表示连接探测通过；第一项真实任务还会验证所用账号、模型和项目是否可执行。

## 6. 模型与推理强度

委派 Agent 任务时配置本节选项；Direct 文件与命令操作无需 Agent 模型。

1. 在设置中找到目标 Agent 的模型区域。
2. 点击“获取模型”或“刷新模型列表”。
3. 选择实际返回的模型 ID。
4. 若该 Agent 提供独立推理选项，选择当前模型返回的值；已缓存的能力可立即切换，尚未获取成功的模型会单独补查。AGY 模型 ID 已包含强度，只需选择模型。
5. 选择后自动保存；保存失败时，按页面提示处理具体错误。

切换模型后，可选推理强度可能变化。DSH ACP 目录来自配置服务的真实响应，原生桌面目录来自已配对 Host；原生模式的选择还会同步 Desktop 默认。接口失败时先解决连接问题，模型与所用服务及账号应匹配。

## 7. 连接 ChatGPT

本节的 OpenAI Platform、Tunnel ID 和 OpenAI Runtime API Key 配置仅用于 ChatGPT / Dot 的 Secure MCP Tunnel。只使用 Gemini 或 Qwen 时，跳过本节。

完整分步说明见 [Tunnel 配置指南](./CHATGPT_DEVELOPER_MODE.md)，包含平台入口、权限和 Key 获取步骤。

流程是：在 OpenAI Platform 创建 Tunnel，明确选择并保存 **WORKSPACES**（个人空间选 **Personal**，团队选对应工作区），再创建受限 Runtime Key，在 Bridge 连接页保存并等待 `ready`。随后在 ChatGPT 侧栏打开 **插件 → 添加 → 创建自定义 MCP 服务器**，选择 **Tunnel** 连接类型并添加 Codex Bridge。Bridge 和 ChatGPT 使用同一个 Tunnel ID。

完成 Tunnel 配置并在 ChatGPT 添加、启用 Codex Bridge 插件后，即可按第 11 节直接读写已授权项目的文件、运行命令，无需连接 Agent。

OpenAI Runtime Key 用于 Tunnel；DSH ACP 的默认 DeepSeek API 连接另行配置 API Key，原生桌面模式复用 Desktop 账号。Runtime Key 不填入 ChatGPT 对话、Qwen 或 Gemini 配置。

## 8. 连接 Qwen Studio

1. 启动与 Bridge 位于同一台电脑、能够访问本机回环 HTTP 的 Qwen 客户端。
2. 在 Bridge“连接 → 本地 MCP 客户端”找到 Qwen，启用该客户端。
3. 点击“复制 Qwen JSON 配置”。
4. 在 Qwen 的 MCP 服务配置中粘贴 JSON 并保存，然后连接/刷新工具。
5. 新建对话，要求调用 `bridge_status` 和 `list_projects` 检查连接。

配置由 App 生成，包括实际端口和客户端凭据。不要手工猜值。云端执行 MCP 的客户端无法通过它自己的 `127.0.0.1` 访问你的电脑。

“重新生成凭证”会使旧凭据失效，之后重新复制配置到 Qwen。“重新生成 Endpoint”会改变本机服务地址，需要更新使用旧地址的客户端。

### 8.1 连接 Gemini 本地 MCP

**本地 MCP 仅用于与 Bridge 位于同一台电脑、能够启动本机程序的 Gemini 桌面 App。** Gemini 网页版（包括 Bridge 内置浏览器）不能使用本地 MCP 启动命令，必须按下一节配置 Cloud MCP。

**本方式无需配置 OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key。** 在 Bridge 登记项目并启用 Gemini 即可开始接入。

1. 在 Bridge 的「连接 → Gemini」中启用 Gemini，并选择客户端工具权限。
2. 在 Gemini 打开 **更多 → 自定义 → 关联应用 → 右上角「＋自定义」**，选择 **本地 MCP**。
3. 服务器名称填写 `Codex Bridge`，说明可选。
4. 返回 Bridge，点击「复制本地启动命令」，将完整命令粘贴到 Gemini 的「命令」栏。
5. 点击「下一步」，核对工具列表后完成关联。在对话中启用该应用，让 Gemini 调用 `bridge_status` 和 `list_projects` 检查连接。

启动命令使用已安装 App 的 `--mcp-stdio` 入口，由本机连接器取得当前服务地址与凭据。无需安装 Node，也无需在 Gemini 填写 Token。使用期间保持 Bridge 后台服务运行；更换 App 安装路径后，重新复制命令并更新 Gemini 配置。

Gemini 与 Qwen、ChatGPT 的启停、凭据和客户端工具权限独立。项目目录、Direct 执行规则、本机审批和 Agent 任务权限继续由 Bridge 管理。

### 8.2 连接 Gemini 云 MCP

**Gemini 网页版（包括 Bridge 内置浏览器）必须使用 Cloud MCP。** Bridge 提供 **ChatGPT Sites（公开）** 和 **ngrok** 两种方式。先在 Bridge 的「连接 → Gemini」启用 Gemini，选择客户端工具权限，再打开「云 MCP」选择接入方式。

**两种云 MCP 都无需配置 OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key。** Sites 需要可使用 ChatGPT Sites 的账号；ngrok 使用自己的 ngrok 账号。Sites 的 `BRIDGE_MCP_KEY` 和 `BRIDGE_RELAY_KEY` 均由 Bridge 生成，用于站点访问与请求回传，与 OpenAI Runtime API Key 无关。

配置中会用到两种地址：

| 地址 | 填写位置 |
| --- | --- |
| 托管服务的 HTTPS 根地址，例如 `https://your-site.your-workspace.chatgpt.site` | Bridge 的云 MCP 地址栏 |
| Bridge「复制 Gemini 专用链接」生成的完整专用链接 | Gemini 的 Cloud MCP 地址栏 |

专用链接包含访问凭据，请保留完整内容，不要自行拼接路径，也不要把根地址直接填入 Gemini。

#### ChatGPT Sites（公开）：让 Codex 帮你配置

1. 准备可使用 ChatGPT Sites 的账号，在 Bridge 的云 MCP 中选择「ChatGPT Sites（公开）」。
2. 将下面的完整提示词复制给有 Sites 部署能力的 Codex。提示词本身不含密钥；Bridge 中「复制 Sites 托管配置」取得的配置，应另行通过受保护的 Secret 配置入口提供，不要贴入公开页面或仓库。

```text
请帮我部署 Codex Bridge 的 Gemini Cloud MCP 转发站点。

请从公开仓库 https://github.com/Fanch-hui/codex-bridge 的 win 分支取得 Integrations/GeminiSites 完整模板，并先阅读该目录的 README。按模板创建一个新的 ChatGPT Sites 站点并公开部署，保留真实的 MCP 请求转发、D1 队列，以及本机 Bridge 主动领取请求和回传结果的接口。使用模板自己的构建脚本，不要用只有演示工具或静态页面的站点代替。

我会另行通过受保护的 Secret 配置方式提供 Bridge「复制 Sites 托管配置」中的两项值。请将 BRIDGE_MCP_KEY 和 BRIDGE_RELAY_KEY 分别设置为站点运行时 Secret；缺少配置时提示我完成 Secret 设置。不要将它们写入源码、hosting.json、公开网页、日志或回复，也不要在回复中输出含密钥的 Gemini 连接链接。

部署完成后，请返回站点的 HTTPS 根地址和部署结果，方便我填回 Bridge。随后告诉我：在 Bridge 保存该根地址并启用云 MCP，等待连接成功，再从 Bridge 复制完整连接链接，到 Gemini 的「更多 → 自定义 → 关联应用 → 右上角『＋自定义』」选择 Cloud MCP，粘贴完整连接链接并将 OAuth 高级选项留空；点击下一步，核对工具列表、将应用名称填写为 Codex Bridge，然后完成关联。
```

3. 按 Codex 提示完成两项运行时 Secret 配置，等待公开部署完成。需要自行部署时，参见[模板与开发者说明](../Integrations/GeminiSites/README.md)。
4. 将 Codex 返回的 **HTTPS 根地址**填回 Bridge，保存并启用云 MCP。保持 Bridge 后台服务运行，等待 Sites 连接成功。
5. 在 Bridge 点击「复制 Gemini 专用链接」。在 Gemini 打开 **更多 → 自定义 → 关联应用 → 右上角「＋自定义」**，选择 **Cloud MCP**。
6. 地址粘贴刚复制的**完整专用链接**，高级 OAuth 配置无需填写，点击「下一步」。
7. 核对工具列表，将应用名称填写为 `Codex Bridge`，完成关联，并在对话中启用该应用。

Bridge 主动向 Sites 领取请求并回传结果，本机无需开放入站端口。站点首页公开不代表工具无权限开放：调用工具仍需完整专用链接，并受 Gemini 客户端权限、项目目录和本机审批限制。使用期间保持 Bridge 后台服务运行。

#### ngrok

ngrok 在运行 Bridge 的电脑上建立公网入口，供 Gemini 网页版通过 Cloud MCP 访问。不需要配置 ChatGPT Sites、OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key。

##### 1. 准备 Bridge 和 ngrok 账号

1. 打开 Bridge，确认概览中的后台 Service 和本地 MCP 可用，并在「项目」登记准备使用的目录。
2. 打开「连接 → Gemini」，启用 Gemini，选择客户端工具权限；在「云 MCP」中选择「ngrok」。
3. 打开 [ngrok 注册页](https://dashboard.ngrok.com/signup)，注册并登录自己的账号；按页面提示完成账号验证。

##### 2. 在运行 Bridge 的电脑安装 ngrok

按自己的操作系统选择一种安装方式，其他系统的步骤跳过。

**macOS：**打开「终端」。如果已安装 Homebrew，运行：

```sh
brew install ngrok
```

没有 Homebrew 时，打开 [ngrok 的 macOS 下载页](https://ngrok.com/download/mac-os)，选择 Download，Apple Silicon 选择 ARM64，Intel 选择 AMD64/x86_64。下载 ZIP 并解压，把解压出的 `ngrok` 文件放到「下载」目录顶层，再运行：

```sh
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$HOME/Downloads/ngrok" /usr/local/bin/ngrok
```

**Windows：**打开 PowerShell，运行下面的命令，通过 Microsoft Store 安装；按提示确认商店协议或安装：

```powershell
winget install ngrok -s msstore
```

如果电脑没有 `winget`，打开 Microsoft Store，搜索 `ngrok` 并安装。安装后关闭并重新打开 PowerShell。

**Ubuntu 24.04：**打开终端，使用系统的 Snap 安装：

```sh
sudo snap install ngrok
```

安装完成后，在终端或 PowerShell 执行：

```sh
ngrok version
```

能显示版本号后再继续。若提示找不到命令，先重新打开终端；Ubuntu 检查 `/snap/bin`，macOS 独立安装检查 `/usr/local/bin` 是否在 PATH 中。安装命令依据 ngrok 官方的 [macOS](https://ngrok.com/download/mac-os)、[Windows](https://ngrok.com/download/windows)、[Linux](https://ngrok.com/download/linux) 下载说明。

##### 3. 配置 ngrok Authtoken

1. 登录 ngrok 控制台，打开 [Your Authtoken](https://dashboard.ngrok.com/get-started/your-authtoken) 页面。
2. 复制自己的 Authtoken，在运行 Bridge 的同一台电脑、同一系统用户的终端执行下面的命令。将 `YOUR_NGROK_AUTHTOKEN` 替换为自己的实际值，保留两侧引号：

```sh
ngrok config add-authtoken "YOUR_NGROK_AUTHTOKEN"
```

命令成功后会提示已保存配置。这个 Authtoken 用于本机 ngrok 登录，与 ngrok API Key、Bridge 的 Gemini 凭据和 OpenAI Runtime API Key 不同；不要填入 Bridge 或 Gemini，也不要贴到对话中。换系统用户或换电脑时，需要在对应用户下重新认证。[命令说明](https://ngrok.com/docs/gateway/agent/cli#ngrok-config-add-authtoken)。

##### 4. 启动指向 Bridge 的隧道

1. 返回 Bridge「连接 → Gemini → 云 MCP」，确认已选择「ngrok」。
2. 点击「复制 ngrok 启动命令」，在刚才的终端或 PowerShell 粘贴并运行。**使用 App 复制的实际命令，不要自行填写端口或照抄官方示例的 80/8080 端口。**
3. 命令形式如下；`62771` 只是示例，实际端口以 App 复制的命令为准：

```sh
ngrok http http://127.0.0.1:62771 --inspect=false
```

保持这个终端窗口运行。看到 ngrok 的 `Forwarding` 行后，确认箭头右边是命令中的本机地址，例如：

```text
Forwarding  https://your-domain.ngrok.app -> http://127.0.0.1:62771
```

**只复制箭头左边的 HTTPS 地址**，例如 `https://your-domain.ngrok.app`。不要复制整行、右边的 `127.0.0.1` 地址或 `Web Interface` 地址。示例域名需要替换为终端实际显示的地址。

##### 5. 把公网根地址保存到 Bridge

1. 将刚复制的 HTTPS 地址填入 Bridge 的「HTTPS 网站根地址」，点击「保存并启用」。这里不添加 `/mcp`，也不填写 Gemini 专用链接。
2. ngrok 方式显示「已配置，等待 Gemini 调用」表示 Bridge 已保存配置；实际连通性在下一步通过 Gemini 的工具调用确认，不需要等待「Sites 已连通」。
3. 点击 Bridge 的「复制 Gemini 专用链接」。完整链接由 Bridge 生成，包含访问凭据，不要手工拼接或截短。

##### 6. 在 Gemini 网页版完成关联

1. 在 Gemini 打开 **更多 → 自定义 → 关联应用 → 右上角「＋自定义」**，选择 **Cloud MCP**。
2. 在「添加自定义应用链接」粘贴 Bridge 刚生成的**完整 Gemini 专用链接**。这里使用专用链接，不是上一步的 HTTPS 网站根地址。
3. 展开「高级设置」时，OAuth 客户端 ID、客户端密钥均留空，不填写 ngrok Authtoken。
4. 点击「下一步」，核对工具列表，将应用名称填写为 `Codex Bridge`，然后点击「关联」。
5. 新建或打开 Gemini 对话，启用 Codex Bridge 应用，发送：

```text
请通过 Codex Bridge 调用 bridge_status 和 list_projects，确认连接并列出已登记的项目。
```

能返回 Bridge 状态和项目列表后，表示此次 Gemini → ngrok → 本机 Bridge 调用已连通。

##### 7. 日常使用与停止

使用期间保持 **Bridge 后台服务和 ngrok 终端进程**运行；电脑关机、休眠、断网或关闭 ngrok 后，Gemini 将无法访问本机工具。重新使用时启动 Bridge，再运行 App 复制的 ngrok 命令。

重新启动后核对终端中的 HTTPS 地址。地址变化时，将新根地址保存到 Bridge，再复制新的完整专用链接并更新 Gemini；Bridge 本机端口变化时，先在 ngrok 终端按 `Ctrl+C` 停止旧转发，重新复制并运行启动命令，再核对公网地址。重置 Gemini 凭据后，也需重新复制专用链接并更新 Gemini。

停止使用时，在 Bridge 点击「停用云 MCP」，再在 ngrok 终端按 `Ctrl+C`。Bridge 的停用按钮不会自动结束你手动启动的 ngrok 进程。

| 遇到的情况 | 处理方法 |
| --- | --- |
| 找不到 `ngrok` 命令 | 完成安装并重新打开终端；确认 ngrok 所在目录在 PATH 中，再运行 `ngrok version`。 |
| 提示账号未认证或 Authtoken 无效 | 在运行 ngrok 的同一系统用户下重新执行第 3 步，使用 ngrok Authtoken，不使用 API Key。 |
| `ERR_NGROK_8012` | ngrok 无法连接本机目标；检查 Bridge 的 Service、本地 MCP 和启动命令中的实际端口，重新复制命令启动。[错误说明](https://ngrok.com/docs/errors/err_ngrok_8012)。 |
| Gemini 导入失败、提示 OAuth 或找不到工具 | 核对使用的是 Bridge 生成的完整专用链接、Gemini 和云 MCP 均已启用、ngrok 正在运行；不要以直接打开网站根地址代替工具调用验证。 |
| ngrok 提示当前账号的连接、流量或其他限额 | 以 ngrok 返回的具体错误为准，在自己的控制台处理限额或结束不用的端点后重试。 |

#### 检查连接与更新凭据

完成任一方式后，让 Gemini 调用 `bridge_status` 和 `list_projects` 检查连接。专用链接具有 Gemini 客户端的工具权限，只应填入自己的 Gemini 配置；不要发布到网页、Issue、日志或对话回复中。

重置 Gemini 凭据后，旧的本地和云端凭据同时失效。云 MCP 需要重新复制完整连接链接并更新 Gemini；使用 Sites 时，还需重新复制「Sites 托管配置」，同步更新站点的两项运行时 Secret。停用云 MCP 不会关闭 Gemini 本地 MCP。

### 8.3 在内置浏览器使用 ChatGPT 或 Gemini

在工作台左侧浏览器工具栏选择 ChatGPT 或 Gemini。App 会记住上次选择及各站点的页面；切换时保留已打开的页面和历史，两站点的登录数据分别保存。后退、前进、刷新和“在外部浏览器打开”作用于当前站点。

如果站点限制内置浏览器登录，可点击“在外部浏览器打开”继续使用。**内置浏览器中的 Gemini 同样属于网页版，必须按第 8.2 节配置 Sites 或 ngrok 云 MCP。** 第 8.1 节的本地 MCP 启动命令只配置在与 Bridge 同机的 Gemini 桌面 App 中。

## 9. 提交第一项任务

本节适用于已连接 Agent 的任务执行。直接文件与命令操作见第 11 节。

### 在工作台管理会话

选择项目与已有 Agent 会话，查看输出并处理工具审批或结构化问题。可通过“原生历史”选择受支持的原生会话；可继续的会话在底部输入区续写，运行中的会话按所选方式插入指令。失败重试沿用原任务配置与附件。

首次任务通过已连接的 ChatGPT 或 Qwen 提交；工作台续写和重试使用可信本地入口。

### 从 ChatGPT 或 Qwen

在已启用 Bridge 的对话中输入：

```text
请通过 Codex Bridge 使用 Codex，读取当前项目 README 并总结用途，不修改文件。
```

客户端应先发现项目和 Agent，再提交相应任务，例如：

```json
{
  "provider_id": "codex",
  "prompt": "读取当前项目 README 并总结用途，不修改文件。"
}
```

项目和模型默认值沿用 App 设置，任务权限使用用户的工作台选择。需要写入或使用网络工具时，用户先将默认任务权限设为“完整”。

默认远程任务需在 Bridge 工作台批准启动。设置中的自动批准远程启动仅影响启动环节；Agent 工具审批和 Direct 操作权限各自生效。

### 任务并发与写入名额

- **同一项目最多 1 个活跃写入任务**，Codex、OpenCode、DeepSeek Harness 和 Antigravity 共用这一限制。
- **不同项目可以同时写入**，但仍受各 Agent 的并发限制。
- **Codex 最多同时执行 4 个会话**，只读与写入合计；这不是整个 App 的统一任务上限。
- **外部 Agent 没有 Bridge 统一设置的总并发上限**，实际并发受项目写入名额、Provider 自身限制和本机资源约束。

写入任务在待本机批准、启动中、运行中、等待权限批准或状态未知时，都会占用该项目的写入名额。只读任务不占用写入名额，但 Codex 只读任务仍占用 Codex 的执行会话名额。

`submit_task` 可设置 `queue_if_busy: true`，在同一项目的写入名额忙碌时进入持久队列；省略时仍立即返回忙碌。排队任务可以取消，等待期间不占写入名额，开始前重新检查项目目录身份、任务权限、Agent 和模型配置。远程请求仍遵循启动审批设置。历史任务记录不计入执行并发限制。

## 10. 输出、审批、继续与中断

| 看到的状态 | 操作 |
| --- | --- |
| 排队中 | 查看等待位置，按需要取消 |
| 等待启动批准 | 核对项目、Agent、权限和任务后批准或拒绝 |
| 运行中 | 查看实时输出与过程卡片 |
| 等待工具审批 | 展开命令、路径和理由，选择本次提供的允许范围或拒绝 |
| 结构化问题 | 按表单回答后提交 |
| 已完成 | 查看最终回复、变更文件及本地结果 |
| 失败 | 查看错误摘要、失败码和相关日志 |
| 已中断 | 按需要继续会话或提交新任务 |

客户端可用 `list_tasks` 按项目查找任务。提交后先获得任务 ID，再调用 `wait_task`，由 Bridge 默认最多等待 300 秒；完成、审批或补充信息会提前返回。到点仍在执行时，客户端可以随时用 `get_task` 查询状态和结果。等待结束或连接断开不取消任务，结果会继续保存。单个工具失败保留在过程记录中，整项任务结果以最终状态为准。

工作台可发送补充指令或中断任务。具体操作服从当前 Agent 的能力；历史续聊选择原项目、原 Agent 安装对应的会话，DSH 的恢复取决于握手能力和已保存会话。模型与安装变化后，先查看连接状态再继续。

补充指令支持多行：Enter 发送，Shift+Enter 换行；中文输入法选词时不会提交。未发送草稿按任务保存在本机，成功提交后清除。任务结束后可选择“交给其他 Agent”，预览并编辑由已有记录组成的摘要，再创建目标 Agent 的新会话。

工作台底部的刷新按钮重新读取当前对话；模型目录在设置中刷新。任务结束后，执行过程默认收起，点击可展开查看工具调用与分析记录；用户指令和最终回复保持显示。会话正文完整保存在本机，较早内容通过“加载更早的消息”按页读取。

## 11. Direct 与 Skills

**Direct 让聊天客户端直接执行授权的文件、命令或 Git 操作，无需安装或连接 Agent。** 在 Bridge 登记项目目录，完成所选聊天客户端的 MCP 接入并在对话中启用 Codex Bridge 后即可使用：ChatGPT / Dot 使用 Tunnel 插件，Qwen 使用本机 HTTP MCP，Gemini 使用本地或云 MCP。

例如，在已启用插件的对话中输入：

```text
请通过 Codex Bridge 直接读取当前项目的 README，说明项目用途。
```

1. 在设置中管理 Direct 执行模式与规则。
2. 在项目中设置需要的 workspace commands。
3. 命令使用可执行文件与结构化参数；按需要设置允许项和黑名单。
4. 写入、命令与 Git 请求按实际策略进入批准流程。

常用工具：

| 目的 | 工具 |
| --- | --- |
| 浏览目录与模块 | `list_project_directory` |
| 一次读取多个文件或行范围 | `batch_read_project_files` |
| 查看运行中命令输出 | `direct_read_command`，首次传 `cursor: "v1.0"`，后续沿用 `next_cursor` |
| 找回近期命令记录 | `list_direct_commands` |
| 预览文件写入、编辑或补丁 | `direct_preview_project_mutation` |
| 应用已预览操作 | `direct_apply_project_mutation` |
| 撤销已应用操作 | `direct_undo_project_mutation` |

命令历史保存脱敏参数、状态和输出摘要。撤销会校验文件仍是本次操作写出的版本；后续已被修改时返回冲突。预览与撤销记录在当前服务运行期间有界保存，过期后需重新预览。

Skills 区域显示本机发现的技能，可查看内容。需要执行时，由客户端使用实际发现的 Skill 和 Action；页面没有编辑接口。

## 12. 日常使用与排查

| 现象 | 优先检查 |
| --- | --- |
| App 连不上 Service | 概览中的启动/注册提示；macOS 后台项目授权；Windows 同目录服务文件 |
| 本地 MCP 端口不可用 | 连接页状态；确需变更时生成新 Endpoint 并更新客户端配置 |
| Agent 未发现 | 安装后在连接页点击“扫描 Agent”，或通过高级路径登记实际入口；DSH 原生模式检查官方桌面安装 |
| Agent 需重新连接 | 已启用 Agent 的程序更新会自动 Probe 并恢复连接；若首页“本机 Agent 引擎”仍提示处理，点击进入连接页查看原因并重连 |
| 模型获取失败 | API Key、Base URL、账号能力和网络；查看对应 Agent 指南 |
| 任务写入被拒绝 | 用户是否选择“完整”、Agent 原生权限和项目写入名额 |
| 项目忙碌 | 等待该项目当前写任务结束后再提交 |
| 已创建隧道，但 ChatGPT 插件中找不到 | 在 Platform 的 Tunnel 编辑页选择并保存 **WORKSPACES**，再回到同一 ChatGPT 工作区刷新隧道列表；详见 [Tunnel 配置指南](./CHATGPT_DEVELOPER_MODE.md#3-创建-tunnel) |
| ChatGPT 连不上 | 按 Tunnel 指南检查两端状态、Workspace、Key 权限 |
| Qwen 连不上 | 本机运行位置、客户端启用状态和最新复制的 JSON |
| 只用 Gemini，是否需要填写 OpenAI 配置 | 不需要。跳过 ChatGPT Tunnel 配置，按第 8.1 / 8.2 节选择本地 MCP、Sites 或 ngrok；Sites 的两项 Secret 由 Bridge 生成。 |
| 任务等待且不输出 | 查看启动审批、工具审批或问题表单 |

日志用于定位具体错误。分享问题时提供系统、App 版本、操作步骤和脱敏错误摘要。密钥保存在系统凭据存储中，配置 JSON 也可能含凭据，请勿公开。

### DeepSeek Harness 推理选项

DSH ACP 的推理选项来自当前所选模型返回的 `thought_level` / `reasoning_effort` 能力；Profile 中的 `off / low / high / max` 只是初始示例，实际值以当前会话返回为准。原生桌面模式使用已配对 Host 的模型能力。切换模型或刷新后选项可能变化，不根据模型名称猜测支持档位。

### Direct 安全模式命令

安全模式的内置规则仅覆盖只读查询、版本查询和受限语法检查。`git branch` 只接受 `--show-current` 或 `--list`；`git tag` 只接受 `--list`，同时支持 `git describe`。内置 Git 查询关闭分页器、文件监视器以及外部 diff/textconv 等执行入口。

`node --version`、`npm --version`、`swift --version`、`rg --version` 和 macOS 的 `xcodebuild -version` 只接受精确的版本查询参数。`node --check` 只接受一个项目根目录内的 `.js`、`.mjs` 或 `.cjs` 文件，不接受其他 Node 执行参数。文件路径不能逃逸项目根目录，指向项目外的符号链接也会被拒绝。`grep -R/--dereference-recursive` 和 `rg -L/--follow` 不属于允许的搜索参数。

`swift build/test`、构建型 `xcodebuild`、`npm test/run` 等会执行项目代码的命令不再属于免审批内置规则。需要使用时，可显式注册为 Direct 命令并配置审批；Full 模式保持原有执行能力。黑名单仍优先于用户规则和内置规则。Windows 继续只使用符合现有信任校验的 EXE，并保留 AppContainer 网络隔离；不会将 npm 的 `.cmd` 入口当作安全 EXE 放行。
