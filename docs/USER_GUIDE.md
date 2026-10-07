# Codex Bridge 详细使用指南

适用于 macOS 14+ Apple Silicon / Intel、Windows x64 / ARM64，以及 Ubuntu 24.04 LTS x64 / ARM64。首次使用按需要选择配置流程：

- **本地读写文件、运行命令**：安装并启动 Bridge → 登记项目目录 → 配置 Tunnel → 添加并启用插件 → 直接操作项目。无需安装或连接 Agent，也无需配置 Agent 模型。
- **委派 Agent 任务**：安装并启动 Bridge → 登记项目目录 → 连接 Agent → 配置模型 → 从工作台或已连接的聊天客户端提交任务。

Qwen Studio 使用本机 HTTP MCP 配置代替 Tunnel 和 ChatGPT 插件，直接文件与命令操作同样无需连接 Agent。

## 文档导航

- [ChatGPT、Tunnel 与 OpenAI Runtime API Key](./CHATGPT_DEVELOPER_MODE.md)
- [DeepSeek Harness ACP 安装、API Key、连接与模型](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) · [原生桌面连接](./DSH_NATIVE_DESKTOP_GUIDE.md)
- [Pi 与 Qoder 安装、地区选择与连接](./PI_QODER_CONNECTION_GUIDE.md)
- [OpenCode 安装与连接](./OPENCODE_CONNECTION_GUIDE.md)
- [Antigravity 安装、连接与权限](./ANTIGRAVITY_CONNECTION_GUIDE.md)

## 1. 客户端与 Agent

ChatGPT 和 Qwen Studio 可以通过 Bridge 直接读写文件、运行命令，也可以委派 Agent 任务；Bridge 工作台用于提交和管理 Agent 任务。直接操作由本机 Bridge 服务的 Direct Workspace 执行。Codex、OpenCode、DeepSeek Harness（DSH）、Antigravity（AGY）、Pi 和 Qoder 是实际执行委派任务的本机 Agent。

```text
ChatGPT ── Secure MCP Tunnel ─┐
Qwen ──── 本机 HTTP MCP ──────┼─ Bridge Service ─ 项目 / Agent / 审批 / 会话
Bridge 工作台 ── 本机 IPC ────┘
```

委派 Agent 任务时，你可以先只用本机工作台，再配置 ChatGPT 或 Qwen。远程任务请求省略 `provider_id` 时使用 Codex；使用其他 Agent 时要明确选择。

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
| 连接 | 连接 Agent、配置 Tunnel、复制 Qwen 配置、管理 DSH MCP |
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

本节用于委派 Agent 任务。只需要本地文件读写和命令执行时，可直接前往第 7 节连接 ChatGPT 或第 8 节连接 Qwen，再按第 11 节使用 Direct。

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

完整分步说明见 [Tunnel 配置指南](./CHATGPT_DEVELOPER_MODE.md)，包含平台入口、权限和 Key 获取步骤。

流程是：在 OpenAI Platform 创建 Tunnel，明确选择并保存 **WORKSPACES**（个人空间选 **Personal**，团队选对应工作区），再创建受限 Runtime Key，在 Bridge 连接页保存并等待 `ready`。随后在 ChatGPT 侧栏打开 **插件 → 添加 → 创建自定义 MCP 服务器**，选择 **Tunnel** 连接类型并添加 Codex Bridge。Bridge 和 ChatGPT 使用同一个 Tunnel ID。

完成 Tunnel 配置并在 ChatGPT 添加、启用 Codex Bridge 插件后，即可按第 11 节直接读写已授权项目的文件、运行命令，无需连接 Agent。

OpenAI Runtime Key 用于 Tunnel；DSH ACP 的默认 DeepSeek API 连接另行配置 API Key，原生桌面模式复用 Desktop 账号。Runtime Key 不填入 ChatGPT 对话或 Qwen 配置。

## 8. 连接 Qwen Studio

1. 启动与 Bridge 位于同一台电脑、能够访问本机回环 HTTP 的 Qwen 客户端。
2. 在 Bridge“连接 → 本地 MCP 客户端”找到 Qwen，启用该客户端。
3. 点击“复制 Qwen JSON 配置”。
4. 在 Qwen 的 MCP 服务配置中粘贴 JSON 并保存，然后连接/刷新工具。
5. 新建对话，要求调用 `bridge_status` 和 `list_projects` 检查连接。

配置由 App 生成，包括实际端口和客户端凭据。不要手工猜值。云端执行 MCP 的客户端无法通过它自己的 `127.0.0.1` 访问你的电脑。

“重新生成凭证”会使旧凭据失效，之后重新复制配置到 Qwen。“重新生成 Endpoint”会改变本机服务地址，需要更新使用旧地址的客户端。

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

**Direct 让聊天客户端直接执行授权的文件、命令或 Git 操作，无需安装或连接 Agent。** 在 Bridge 登记项目目录、完成 Tunnel 和插件接入（Qwen 使用本机 HTTP MCP）后即可使用。

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
| 任务等待且不输出 | 查看启动审批、工具审批或问题表单 |

日志用于定位具体错误。分享问题时提供系统、App 版本、操作步骤和脱敏错误摘要。密钥保存在系统凭据存储中，配置 JSON 也可能含凭据，请勿公开。

### DeepSeek Harness 推理选项

DSH ACP 的推理选项来自当前所选模型返回的 `thought_level` / `reasoning_effort` 能力；Profile 中的 `off / low / high / max` 只是初始示例，实际值以当前会话返回为准。原生桌面模式使用已配对 Host 的模型能力。切换模型或刷新后选项可能变化，不根据模型名称猜测支持档位。

### Direct 安全模式命令

安全模式的内置规则仅覆盖只读查询、版本查询和受限语法检查。`git branch` 只接受 `--show-current` 或 `--list`；`git tag` 只接受 `--list`，同时支持 `git describe`。内置 Git 查询关闭分页器、文件监视器以及外部 diff/textconv 等执行入口。

`node --version`、`npm --version`、`swift --version`、`rg --version` 和 macOS 的 `xcodebuild -version` 只接受精确的版本查询参数。`node --check` 只接受一个项目根目录内的 `.js`、`.mjs` 或 `.cjs` 文件，不接受其他 Node 执行参数。文件路径不能逃逸项目根目录，指向项目外的符号链接也会被拒绝。`grep -R/--dereference-recursive` 和 `rg -L/--follow` 不属于允许的搜索参数。

`swift build/test`、构建型 `xcodebuild`、`npm test/run` 等会执行项目代码的命令不再属于免审批内置规则。需要使用时，可显式注册为 Direct 命令并配置审批；Full 模式保持原有执行能力。黑名单仍优先于用户规则和内置规则。Windows 继续只使用符合现有信任校验的 EXE，并保留 AppContainer 网络隔离；不会将 npm 的 `.cmd` 入口当作安全 EXE 放行。
