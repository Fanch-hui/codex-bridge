# Antigravity / AGY 连接与权限指南

适用于 Codex Bridge v1.1.0。
本指南说明如何让 Antigravity CLI 在 Codex Bridge 中正常完成只读分析、联网检索和项目写入。Bridge 使用的是 `agy` CLI 的 headless `stream-json` 模式，不是 Antigravity Desktop App。

Provider ID 固定为：

```text
antigravity
```

省略 `provider_id` 时，Bridge 会使用 Codex，不会自动选择 AGY。

## 自动发现与连接

Bridge 首次初始化时扫描本机 Agent 并保存结果。打开连接页后，选择已发现的 Agent 并点击“连接”；需要授权或配置的项目会在连接时提示。后续安装或移动 Agent，可点击“扫描 Agent”更新目录。App 与后台服务重启、切页及日常状态刷新都复用保存的结果。

## Antigravity 2.0 与 AGY CLI 的关系

Antigravity 2.0 与 AGY CLI 是两个界面，但官方说明它们使用同一套 Agent harness，并同步核心偏好、权限和安全设置。CLI 中的 `/settings`（`/config`）和 `/permissions` 修改，原则上也会影响 Antigravity 2.0；反向修改同样适用。对话默认不会自动在两个界面之间出现，需要使用官方的对话导入功能。

Bridge 不启动或嵌入 Antigravity 2.0，而是启动已登记的 `agy` CLI，以 headless `stream-json` 协议执行任务。

```text
Bridge Desktop → Bridge Service → agy --input-format stream-json → AGY CLI
```

Bridge 启动 `agy` 时继承当前系统用户的 `HOME`、登录状态和 CLI 配置，并使用该 CLI 的原生 Sandbox、Tool Permission 与 `/permissions` 规则。CLI 的持久设置位于 `~/.gemini/antigravity-cli/settings.json`（Windows 为 `%USERPROFILE%\.gemini\antigravity-cli\settings.json`）。官方资料明确保证 Desktop 与 CLI 的核心设置同步，但没有把每一种登录会话或凭据文件都承诺为可互换；CLI 会从当前用户的系统钥匙串、Secret Service 或 Windows Credential Manager 读取 token profile。若 CLI 不能读取 Desktop 建立的登录状态，应在同一系统用户下运行 `agy` 完成一次官方登录。使用 Gemini API key 时，CLI 需要 `modelProvider=gemini` 和 `GEMINI_API_KEY`；Bridge 只在其 Service 启动环境中已有该变量时转发它，不在 Bridge 中保存 AGY API key。完成配置后，应先在 `agy` CLI 中确认登录、模型和需要的权限，再从 Bridge 连接。

Bridge 桌面 App 中的设置边界如下：

| 设置 | 作用范围 |
| --- | --- |
| `设置 → Antigravity 默认偏好` | 只保存 AGY 的模型、effort 和只读/写入默认模式 |
| `设置 → OpenCode 默认偏好` | 只保存 OpenCode 的模型、effort 和 Plan/Build 默认模式 |
| `设置 → Codex 执行默认偏好` | 只保存 Codex 的模型、effort、访问模式和快速模式 |
| 项目访问策略、工作台 Read Only/Write、远程启动批准 | Bridge 任务级约束；会按目标 Provider 映射为对应的原生执行模式 |
| AGY `/settings`、`/config`、`/permissions` | 控制 AGY 的原生工具权限和规则；核心设置按官方行为与 Antigravity 2.0 同步 |

因此，Antigravity 2.0 与 AGY CLI 会共享 AGY 自己的核心设置、权限和安全配置；OpenCode 与 AGY 不会共享彼此的 Provider 配置。Bridge 的桌面 App 只提供统一的项目、任务、模型和审批控制面，Codex 的访问模式也不会作为 AGY 的工具放行开关。

## 1. 先理解权限链

AGY 任务能否成功由三层共同决定：

```text
Bridge 项目和任务模式
        ↓
Bridge 远程任务启动批准
        ↓
AGY CLI 原生 Sandbox + Global Permissions
```

最常见的误区是只在 Bridge 中选择 `Write`，却没有配置 AGY CLI 自己的权限。Bridge 不能在 headless `stream-json` 中回答 AGY 的交互式确认；需要询问但没有提前放行的工具会被 AGY 拒绝或软拒绝。

| 设置 | 控制什么 |
| --- | --- |
| `项目 → 访问与执行权限` | 项目可读、是否允许进入写模式，以及用户期望的网络边界 |
| `工作台 → GPT/Qwen 新任务` | ChatGPT/Qwen 默认使用 `Read Only` 还是 `Write` |
| “批准启动” | 是否启动这一次远程 Provider 任务 |
| AGY `/settings` 或 `/config` | Tool Permission 等 CLI 全局行为 |
| AGY `/permissions` | 哪些命令、URL 和 MCP 工具可以在 headless 中直接执行 |

“自动批准远程 Agent 启动请求”只跳过启动批准，不批准 AGY 工具。Antigravity 2.0 的核心权限设置会按官方行为与 CLI 同步，但 Bridge 这次任务仍由 `agy` CLI 的命令行参数和配置执行。

> **连接 AGY 前必须确认**：Bridge 的 AGY 连接流程会在页面中明确请求将当前用户的 AGY Global **Tool Permission** 设为 `always-proceed`（Always Proceed，总是通过）。这是 headless 任务无法回答交互式工具确认的前置条件。用户取消时不修改设置，也不会连接；用户同意后，Service 才会 Probe 并写入当前用户的 Global 配置。该设置会影响使用同一用户配置的其他 AGY CLI 任务。

Bridge 每次启动 AGY 仍会传入 `--sandbox`，项目读写策略和任务模式继续生效。`proceed-in-sandbox` 适合交互式 AGY 或不使用 Bridge 的场景；如果在 Bridge 连接后手动改回该模式，未通过 `/permissions` 提前放行的 headless 工具可能被拒绝。

## 2. 兼容要求

Bridge 根据安装的 CLI 实际接口判断兼容性。Probe 读取 `agy --version` 用于识别和展示，并检查 `agy --help` 是否提供必需接口：

- `--input-format stream-json`
- `--output-format stream-json`
- `--mode plan`
- `--sandbox`
- `--dangerously-skip-permissions`

以下可选能力按当前帮助中的声明开放：

- `--mode accept-edits`
- `--conversation`
- `--model`
- `--effort`

必需接口齐全时，CLI 升级后继续通过同一 Probe；缺少必需接口时，Probe 会报告协议能力不兼容。
其中 `--dangerously-skip-permissions` 只是当前适配器用来确认 CLI 接口完整性的能力项；Bridge 不从 Codex 的访问模式推导它，也不会把 Codex 的 `full-access` 作为 AGY 工具放行设置。

## 3. 安装并找到正确的 AGY 二进制

### 3.1 安装

如果尚未安装，请先阅读 [Antigravity CLI Installation & Auth](https://antigravity.google/docs/cli/install/)。官方安装方式会随平台和版本变化，常用命令如下：

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

默认会把 AGY 安装到当前用户的：

```text
~/.local/bin/agy
```

Windows PowerShell：

```powershell
irm https://antigravity.google/cli/install.ps1 | iex
agy --version
agy --help
```

Windows 安装器通常把 CLI 放在当前用户的 `%LOCALAPPDATA%\agy\bin\agy.exe`；以 `Get-Command agy` 的实际结果为准。Windows 的 CMD 安装命令和其他平台选项见官方安装页。

安装脚本和版本可能更新；以官方安装页为准。企业账号、代理或 Keychain 认证也应按该页配置，不要把认证材料交给 Bridge。

### 3.2 找到二进制

在终端运行：

```bash
command -v agy
agy --version
agy --help
```

Windows PowerShell 使用：

```powershell
Get-Command agy
agy --version
agy --help
```

`command -v agy` 输出的文件就是 Bridge 应登记的二进制。例如：

```text
/Users/你的用户名/.local/bin/agy
```

不要选择：

- Antigravity Desktop 的 `.app`；
- `/Applications/Antigravity.app` 内任意可执行文件；
- 一个只包含快捷方式但目标已失效的路径；
- 从其他账号目录复制来的 AGY。

如果路径位于 `.local` 等隐藏目录，在 macOS Bridge 文件选择器中按 `⌘⇧G`，粘贴 `command -v agy` 的完整输出，再选择该文件。Windows 选择 `Get-Command agy` 返回的真实 `.exe`、`.cmd` 或 `.bat` 路径。

## 4. 先用同一系统用户完成 CLI 登录

Bridge 启动 AGY 时继承当前系统用户的 `HOME` 和登录状态。macOS/Linux 使用该用户的 shell，Windows 使用该用户的 PowerShell；先在准备使用的项目根目录运行一次交互式 CLI：

```bash
cd /path/to/your/project
agy
```

按 AGY 自己的流程完成登录，确认能够进入交互界面并看到可用模型。然后退出即可。

没有现有登录状态时，AGY 会按官方流程打开浏览器或请求 API key，并把认证状态保存在系统凭据存储。完成一次登录后，headless `stream-json` 才能复用该用户的缓存凭据。不要把 API key、浏览器授权码、Token、Cookie 或账号信息粘贴到 Bridge、聊天、日志或 Issue；也不要用临时或隔离的 `HOME` 代替正式用户目录测试登录。

## 5. 正确配置 AGY 原生权限

### 5.1 连接 Bridge 所需的 Tool Permission

在目标项目根目录启动交互式 `agy`，输入：

```text
/settings
```

也可以使用别名：

```text
/config
```

找到 **Tool Permission**。如果你准备从 Bridge 连接 AGY，不需要手动先改设置：点击 Bridge 中的“连接”时，Bridge 会展示明确的 Always Proceed 授权提示；同意后 Service 会将当前用户的 Global 配置写为：

```text
always-proceed
```

这是 Bridge headless 任务可以自动完成工具调用的条件。连接确认只在用户明确同意后发生；取消不会改变现有配置。连接成功后，如果在 AGY 里再次打开 `/settings` 或 `/config`，应能看到 `always-proceed`。由于 AGY Desktop 与 CLI 共享核心设置，该配置也可能影响 Antigravity 2.0 中的后续任务，以及使用同一用户配置的其他 AGY CLI 任务；不会改变 Codex 或 OpenCode 的权限。Bridge 每次启动 AGY 都会显式传入 `--sandbox`，所以这次任务不依赖 Desktop 界面的 Sandbox 开关。

其他模式的含义：

| 模式 | 行为 | Bridge 使用建议 |
| --- | --- | --- |
| `request-review` | 写入、命令和网络操作通常要求交互确认 | 适合交互式 AGY；Bridge headless 无法回答未预先放行的确认 |
| `proceed-in-sandbox` | Sandbox 内命令可自动运行 | 适合交互式 AGY；在 Bridge 中需配合窄 allow 规则 |
| `strict` | 更多非读取操作要求确认 | 适合交互式审查；不适合作为未配置规则的 Bridge 默认 |
| `always-proceed` | 工具调用自动继续 | Bridge 连接所需的 Global 模式；风险高，并影响同一用户的其他 AGY CLI |

AGY 将持久设置保存在：

```text
~/.gemini/antigravity-cli/settings.json
```

Windows 对应路径为：

```text
%USERPROFILE%\.gemini\antigravity-cli\settings.json
```

优先通过 `/settings` 和 `/permissions` 修改，避免手工写错 JSON。由于 Desktop 与 CLI 的核心设置会同步，在任一界面修改 Tool Permission 都可能改变另一界面的默认行为；但 Bridge 这次执行仍以 `agy` CLI 的命令行覆盖和当前配置为准。Bridge 连接后若手动改回其他模式，未配置 allow 规则的工具可能被 AGY soft-deny；需要再次连接时，Bridge 会重新请求 Always Proceed 授权。

### 5.2 用 `/permissions` 添加窄规则

仍在目标项目的交互式 `agy` 中输入：

```text
/permissions
```

按以下顺序操作：

1. 在 Scope Picker 中优先选择 **Project**，只让规则作用于当前项目；只有确实希望所有项目共享时才选择 **Global**。
2. 进入规则列表后切换到 **allow** 页。
3. 按 `A` 添加规则。
4. 输入 `action(target)` 形式的规则并保存。
5. 检查 **ask** 和 **deny** 页是否存在更宽的冲突规则。

常用规则示例：

```text
command(git status)
command(git diff)
command(swift test)
read_url(developer.apple.com)
execute_url(example.com)
mcp(server-name/tool-name)
```

规则含义：

| 操作 | 规则形式 | 示例 |
| --- | --- | --- |
| Shell | `command(命令前缀)` | `command(pnpm test)` |
| 读取网页 | `read_url(域名)` | `read_url(github.com)` |
| 操作网页 | `execute_url(域名)` | `execute_url(platform.openai.com)` |
| MCP | `mcp(server/tool)` | `mcp(linter/check)` |
| 工作区文件 | `read_file(path)` / `write_file(path)` | 只在确有需要时为项目内相对路径添加 |

AGY 的优先级是：

```text
deny > ask > allow
```

例如存在 `ask: command(*)` 时，即使 allow 中有 `command(git status)`，仍可能要求确认。只在理解影响后缩小冲突规则；不要用 `command(*)`、`read_url(*)` 或 `mcp(*)` 代替必要的精确授权。

### 5.3 文件写入为何通常不需要额外规则

Bridge 对写任务传入：

```text
--mode accept-edits
```

AGY 的 Accept Edits 会自动批准活动工作区内的标准文件创建和修改。Shell、Web、MCP、工作区外路径仍是独立权限，必须由 `/permissions` 或其他明确策略处理。

只读任务则传入：

```text
--mode plan
```

Plan 用于分析和规划，不应依赖它修改项目文件。

## 6. 在 Bridge 中连接和启用

1. 打开 `连接 → 本机 Agent 引擎连接`。
2. 共享桌面页面会自动查找 `agy`/`antigravity`。在 AGY 卡片中点击“连接”；如果没有自动发现，选择“按路径登记已有安装”。按路径登记时选择第 3 节命令返回的真实文件。
3. AGY 连接前，页面会显示以下授权提示：

   ```text
   AGY 无头任务需要自动通过工具执行。是否允许将本机 AGY 全局工具策略设为 Always Proceed（总是通过）并连接？这会影响使用同一配置的 Antigravity 2.0 和其他 AGY CLI 任务。
   ```

   只有点击同意后，Service 才会连接候选、执行 Probe，并把当前用户的 AGY Global `toolPermission` 设为 `always-proceed`；取消不会修改设置。
4. 检查版本、能力和状态。连接流程 Probe 成功时会自动启用可用安装；手动“登记 Agent”则需在状态为“可用”后打开“启用”。

已启用的 AGY 更新或二进制身份变化后，Bridge 会自动重新 Probe；检查当前 CLI 实际帮助能力，通过后保留原连接，不使用固定版本范围。启动 App 和后台刷新都会触发检查；自动恢复不修改已有的 Always Proceed 授权。接口不兼容、旧路径无法明确重新发现等情况会在首页“本机 Agent 引擎”提醒，点击进入连接页查看原因并手动重连。移除登记只删除 Bridge 的连接记录，不删除 AGY CLI、登录状态或 Global 配置。

## 7. 刷新模型和默认值

1. 先在 `工作台` 选择真实任务项目。
2. 打开 `设置 → 外部 Agent 默认偏好`，找到 `Antigravity` 执行默认偏好。
3. 有多个安装时选择目标 AGY。
4. 点击“刷新模型列表”。Bridge 读取当前 AGY 安装实际返回的模型目录，不会补入静态或过期模型。
5. 选择当前返回的精确 model 和 effort；推理强度只显示所选模型声明支持的值。
6. 选择 Provider 默认访问权限：只读或工作区可写。

对 ChatGPT/Qwen 新任务，`工作台 → GPT/Qwen 新任务 → Read Only / Write` 是 Bridge 的任务级选择，会映射为 AGY 的 `plan` 或 `accept-edits`；它不修改 AGY 的 Global Tool Permission。远程客户端通常应省略 `permission_mode`，让 Workbench 决定；只有用户明确要求单任务覆盖时才同时发送 `permission_mode_override=true`。

连接完成后，连接详情会显示 AGY Global Tool Permission。使用 Bridge headless 任务期间应保持 `always-proceed`；需要收窄行为时优先在 AGY `/permissions` 为具体命令、域名或 MCP 工具添加 Project 规则。

## 8. Bridge 实际如何启动 AGY

只读任务的核心参数：

```text
agy
--sandbox
--input-format stream-json
--output-format stream-json
--mode plan
--add-dir <项目根>
```

写任务的核心参数：

```text
agy
--sandbox
--input-format stream-json
--output-format stream-json
--mode accept-edits
--add-dir <项目根>
```

Bridge 不再给 AGY 套外层 `sandbox-exec`。真实文件、命令、Web 和 MCP 约束由 AGY 原生 Sandbox、执行模式和权限规则负责。

## 9. 三种正常使用场景

### 9.1 只读分析，不联网

Bridge：

1. `项目`：读取“允许”、写入“拒绝”。
2. `工作台`：选择正确项目和 `Read Only`。
3. `设置 → Antigravity 执行默认偏好`：默认权限选“只读”。
4. 任务使用 `network_access=false`。

请求示例：

```json
{
  "provider_id": "antigravity",
  "prompt": "只读分析当前项目并说明问题，不要修改文件。",
  "network_access": false
}
```

这种任务会使用 `--mode plan`，不会加入 `--dangerously-skip-permissions`。如果 prompt 要求运行 Shell，仍应提前添加对应的窄 `command(...)` allow 规则。

### 9.2 只读联网

1. 保持 Workbench 为 `Read Only`。
2. 项目读取设为“允许”，网络意图设为“允许”或“需要本机批准”。
3. 在 AGY `/permissions` 中只放行需要访问的 `read_url(domain)`、`execute_url(domain)`，以及必要命令/MCP。
4. 任务显式发送 `network_access=true`。

```json
{
  "provider_id": "antigravity",
  "prompt": "搜索并核对官方资料，给出来源；不要修改项目。",
  "network_access": true
}
```

`network_access=true` 只表达用户明确的联网意图，不会替你创建 AGY allow 规则。当前项目网络选择器也不是外部 Provider 的网络包级防火墙；最终仍以 AGY 原生 `read_url`、`execute_url`、Sandbox 和命令规则为准。

原生 `search_web` 可能不需要本地缓存写入，但 `read_url_content`、浏览器、第三方插件或辅助脚本可能需要额外 URL、命令、MCP 或本地状态权限。看到拒绝时按失败的具体工具补最窄规则，不要直接开放全部权限。

### 9.3 修改项目文件

1. `项目`：读取“允许”、写入“允许”。
2. `工作台`：选择 `Write`。
3. 确认同一项目没有其他活动写任务。
4. 在 AGY `/permissions` 中放行构建、测试和查询所需的窄命令/网络规则。
5. 任务不需要联网时使用 `network_access=false`。

```json
{
  "provider_id": "antigravity",
  "prompt": "实现指定修改并运行相关测试。",
  "network_access": false
}
```

Bridge 使用 `--mode accept-edits`，同一项目的写任务进入独占 workspace gate。项目写入为“需要本机批准”不会给 AGY 增加逐文件审批；希望硬性禁止写入时应选择“拒绝”。

## 10. 从 ChatGPT/Qwen 提交

先让客户端调用：

```text
list_projects
list_agents
list_models
```

确认：

- `provider_id` 为 `antigravity`；
- 安装 `availability` 为 `available`；
- `enabled` 与 `task_submission_enabled` 为 `true`；
- Workbench 已选中正确项目和权限。

有多个 AGY 安装时，使用 `list_agents` 返回的精确 `installation_id`。模型覆盖只在用户明确指定时设置 `model_override=true`，model/effort 必须来自当前 AGY 目录。

远程任务默认先进入：

```text
awaiting_local_approval
```

在 Bridge 工作台核对项目、Provider、Read Only/Write、网络意图和 prompt 后点击“批准启动”。AGY 后续工具不会进入可交互的 App 审批卡片；权限不足时应回到 AGY `/permissions` 修正规则后重试。

## 11. 常见故障

已启用的 AGY 遇到临时检查失败时，Bridge 会在后续状态刷新中自动重试，失败重试间隔至少 30 秒；恢复后继续使用原安装记录。主动禁用的安装需要用户启用。可执行文件内容或路径真正变化时，仍需确认更新。此行为适用于包含连接恢复修复的后续构建。

| 现象 | 正确处理 |
| --- | --- |
| 找不到可执行文件 | 运行 `command -v agy`；在文件选择器按 `⌘⇧G` 粘贴该绝对路径 |
| 误选 Desktop App | 重新登记真实 `agy` CLI；Bridge 不运行 Antigravity Desktop |
| Probe 提示缺少协议能力 | 检查当前 `agy --help` 是否包含 stream-json、plan、sandbox 和工具权限参数 |
| 显示 `needs_review` | 二进制已变化；核对来源和版本后“接受替换并 Probe” |
| Bridge 中提示未登录 | 用同一系统用户在普通 `HOME` 下交互运行 `agy` 完成登录；Windows 使用同一用户的 `USERPROFILE` |
| 连接时提示 Always Proceed | 这是 AGY headless 连接的明确授权步骤；同意后 Bridge 才会 Probe 并连接，取消不会改配置 |
| 手动改为 `request-review` / `proceed-in-sandbox` 后工具被拒绝 | Bridge headless 无法回答交互确认；保持连接所需的 `always-proceed`，或在 AGY `/permissions` 为具体工具添加 Project allow 规则 |
| 已添加 allow 仍被询问 | 检查 ask/deny 是否匹配同一操作；AGY 优先级为 `deny > ask > allow`，并确认规则作用域是当前 Project |
| Shell 仍被拒绝 | 放行精确 `command(...)`；若命令必须逃离 Sandbox，应先评估风险，不要默认扩大到全部命令 |
| Web/URL 被拒绝 | 任务发送 `network_access=true`，并为具体域名添加 `read_url(domain)` / `execute_url(domain)` |
| MCP 工具被拒绝 | 在 AGY `/permissions` 添加精确 `mcp(server/tool)`，不是修改 Bridge MCP 客户端权限 |
| Desktop 已设自动执行仍无效 | Desktop 与 CLI 的核心设置按官方行为同步；检查 CLI 是否使用同一系统用户/钥匙串、是否有命令行覆盖，以及 AGY `/settings` 和 `/permissions` |
| 只读搜索能用，URL/辅助脚本失败 | 后者可能需要 URL、命令、MCP 或缓存写入权限；按实际失败工具补窄规则 |
| 写任务没有修改文件 | Workbench 是否为 `Write`、项目写入是否允许、任务是否实际使用 `--mode accept-edits` |
## 12. 安全与验收

- 不读取、复制或提交 AGY 的认证文件、Token、Cookie 或浏览器授权响应。
- 优先使用 Project 作用域和精确规则，不使用全局通配符代替必要配置。
- Probe 成功只证明二进制、版本、帮助能力和基础 Provider 行为可用，不证明账号额度、Web、Shell、MCP 或写入已验收。
- 最终使用自己的账号，在可回滚的测试项目中分别验证只读、联网、写入、命令和会话继续。

## 13. 参考

- [Antigravity CLI Installation & Auth](https://antigravity.google/docs/cli/install/)
- [Antigravity CLI Overview](https://antigravity.google/docs/cli/overview/)
- [Antigravity CLI 与 Antigravity 2.0（官方说明）](https://www.antigravity.google/blog/introducing-google-antigravity-cli)
- [Antigravity CLI Settings](https://antigravity.google/docs/cli/settings/)
- [Antigravity CLI Permissions](https://antigravity.google/docs/cli/permissions/)
- [Permissions Command](https://antigravity.google/docs/cli/commands/permissions/)
- [Antigravity CLI Headless Mode](https://antigravity.google/docs/cli/headless/)
- [Codex Bridge 详细使用指南](./USER_GUIDE.md)
