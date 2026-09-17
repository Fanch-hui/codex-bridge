# OpenCode 连接指南

本指南说明如何把本机已安装的 OpenCode 登记到 Bridge，并让 ChatGPT、Qwen Studio 或 Bridge 工作台通过 MCP 提交 OpenCode 任务。实际兼容范围以当前 Bridge 适配器的 Probe 结果为准。

## 先说明连接方向

OpenCode 不是 MCP 客户端，也不是要求把 Bridge 加到 OpenCode 的 MCP 列表中。正确的数据流是：

```text
ChatGPT / Qwen Studio → Codex Bridge MCP → OpenCode ACP → 已登记的本地项目
```

Bridge 会在任务批准后启动：

```text
opencode acp --cwd <已登记的项目根目录>
```

OpenCode 不随 Bridge 打包，Bridge 也不会读取、复制或导出 OpenCode 的登录凭据。

## 1. 安装并登录 OpenCode

请先阅读 [OpenCode 官方文档](https://opencode.ai/docs/)。常用安装方式如下：

```bash
# macOS / Linux
curl -fsSL https://opencode.ai/install | bash

# npm
npm install -g opencode-ai
```

也可以按官方文档使用 Homebrew、Bun、pnpm、Yarn、Scoop 或 Chocolatey。使用 Windows 版 Bridge 时安装 Windows 原生 CLI，例如在 PowerShell 运行上面的 npm 命令；登记可执行的 CLI 入口。仅在 WSL 内安装的 Linux CLI 不能直接作为 Windows Bridge 的本机入口。

在目标项目中启动 OpenCode：

```bash
cd /path/to/your/project
opencode
```

在 OpenCode 中输入 `/connect`，按页面提示选择 Provider，并在 Provider 页面完成登录、订阅或 API key 配置。API key 只应交给 OpenCode 的官方登录流程，不要粘贴到 Bridge、聊天、日志或 Issue。可以使用 `/init` 让 OpenCode 为项目生成初始说明，但这不是 Bridge 连接的必要步骤。

先在 OpenCode 自己的界面确认所需模型可用，再退出交互界面。Bridge 的模型目录来自 ACP，会以当前项目根启动一次 ACP `session/new` 读取 Provider 实际返回的模型和模式能力。

## 2. 兼容性和 Probe

Bridge 通过 ACP 握手判断 OpenCode 是否可用，而不是仅根据命令行版本号判断。Probe 会检查：

- 能否启动 `opencode acp --cwd <项目根目录>`；
- ACP 协议版本是否为当前适配器支持的版本；
- Agent 名称和版本字段是否正常返回；
- `session/new`、模型配置选项和当前任务所需能力是否可用。

适配器的兼容判定会随 Bridge 版本更新，本文不固定 OpenCode 的版本上限或下限。连接页显示的 Probe 结果是当前安装能否使用的依据；升级 OpenCode 后应重新 Probe，遇到“需复核”时先核对来源，再接受替换并 Probe。

## 3. 在 Bridge 中发现、登记和启用

1. 打开 Codex Bridge，先在“项目”页面登记要使用的本地项目。
2. 进入“连接” → “本机 Agent 引擎连接”。
3. Bridge 会查找本机安装的 OpenCode。共享桌面页面显示候选后，点击 OpenCode 卡片中的“连接”；需要指定路径时，使用“按路径登记已有安装”。
4. 如果需要选择文件，选择真实的绝对路径下的 `opencode` CLI；Windows 选择 `opencode.exe`、`opencode.cmd` 或 `opencode.bat`，不要选择 GUI 桌面程序。
5. 快捷连接在 Probe 成功后自动启用；高级手动登记则在状态为“可用”后启用。显示“已连接”表示该安装已经可供任务提交。

Bridge 的自动发现只读取必要的安装元数据，不会执行未连接的候选二进制。登记时会冻结规范路径、文件身份、大小、修改时间和 SHA-256；OpenCode 更新后状态会变成“需复核”。只有在确认这是你预期的更新后，才点击“接受替换并 Probe”。

## 4. 刷新模型和设置默认值

在“设置” → “外部 Agent 默认偏好”中找到 OpenCode：

1. 连接 OpenCode，并在工作台选择一个真实项目。
2. 点击“刷新模型列表”。模型目录来自当前项目根启动的 ACP `session/new.configOptions`，不是 `opencode models` CLI 的输出。
3. 选择 ACP 返回的精确模型 ID。不要手动在 `opencode/...` 与其他 Provider 的名称之间改名或使用别名。
4. 仅当当前模型通过 ACP 声明了 effort 选项时，才选择对应 effort；没有可用选项时使用 Provider 默认值。
5. 保存 OpenCode 的默认模型、effort 和访问权限。ChatGPT/Qwen 新任务的统一权限默认值在“工作台 → GPT/Qwen 新任务”中选择：
   - **Write** 映射 OpenCode Build；
   - **Read Only** 映射 OpenCode Plan。

远程请求通常应省略权限覆盖字段并使用 Workbench 默认。只有用户明确要求本次覆盖时，才发送 `permission_mode_override=true`；项目硬策略仍可把 Build 收窄为只读。

模型和 effort 的有效值以当前 ACP 返回的能力为准。刷新失败会保留已有列表和默认设置；如果 OpenCode 删除了当前默认模型或 effort，Bridge 会清空失效的默认值，并在设置页显示错误或要求重新选择。

访问权限与工作台模式的关系如下：

| Bridge 模式 | OpenCode ACP 模式 | 作用 |
| --- | --- | --- |
| `Read Only` | `plan` | 只读分析和规划 |
| `Write` | `build` | 允许在项目工作区内修改文件 |

ChatGPT/Qwen 新任务通常应省略权限覆盖字段，让工作台选择生效。项目策略禁止写入时，Bridge 会把 Build 安全收窄为只读；Provider 默认值不能越过项目策略。

## 5. 从 ChatGPT 或 Qwen 通过 MCP 提交

先调用 `list_projects` 获取不透明的项目 ID，再调用 `list_agents` 确认 OpenCode 安装满足：

```json
{
  "provider_id": "opencode",
  "availability": "available",
  "enabled": true,
  "task_submission_enabled": true
}
```

最小任务请求：

```json
{
  "project_id": "<list_projects 返回的项目 ID>",
  "provider_id": "opencode",
  "prompt": "检查项目结构并总结当前构建问题。",
  "network_access": false
}
```

只有用户明确要求覆盖模型或权限模式时，才增加覆盖字段：

```json
{
  "project_id": "<项目 ID>",
  "provider_id": "opencode",
  "installation_id": "<可选的 installation_id>",
  "prompt": "修复指定测试失败，并运行相关测试。",
  "model_override": true,
  "execution_model": "<ACP 返回的精确 model_id>",
  "execution_effort": "<该模型实际支持的 effort>",
  "permission_mode": "workspace-write",
  "permission_mode_override": true,
  "network_access": false,
  "acceptance_criteria": [
    "相关测试通过",
    "只修改项目内文件"
  ],
  "client_request_id": "<客户端生成的幂等 ID>"
}
```

字段规则：

- `provider_id` 为 `opencode`；省略时仍走默认 Codex 路径。
- `installation_id` 可省略，Bridge 会选择已启用且 Probe 可用的安装；有多个安装时应使用 `list_agents` 返回的精确 ID。
- `execution_model` 和 `execution_effort` 只有在 `model_override=true` 时才覆盖本次任务。
- `permission_mode` 只能是 `read-only` 或 `workspace-write`；它们分别映射为 ACP Plan 和 Build。
- 只有用户明确要求本次模式时，才设置 `permission_mode_override=true`。
- `network_access` 表达本次任务的联网意图。OpenCode ACP 不套用 Bridge 级逐任务网络沙箱，实际网络行为由 OpenCode 原生权限设置控制。
- 新建 OpenCode 会话时省略 `thread_id`；继续已有会话时，将上一任务 `get_task` 返回的 `provider_session_id` 作为 `submit_task.thread_id`。只有用户明确选择已发现的 Bridge Skill 时才携带 `skill_name`，其余字段以当前 MCP 工具 schema 为准。
- 项目本身禁止写入时，默认 Build 会安全收窄为只读，不会越过项目策略。

## 6. 审批、查询和继续任务

`submit_task` 通常先返回 `awaiting_local_approval`。本机用户在 Bridge 工作台批准后，任务才进入 `starting` 和 `running`。设置中的“自动批准远程 Agent 启动请求”默认关闭；即使开启，也不会自动批准 OpenCode 执行期 permission 或 Direct 操作。

使用 `get_task` 查询阶段、`result_summary`、`failure_code`、`changed_files`、`recent_activity`、`execution_model`、`execution_effort`、`permission_mode` 以及 Provider 绑定字段。按它返回的 `wait_policy` 继续查询；进入终态后，直接从同一 `get_task` 快照读取最终结果。`next_action=read_final_report` 只是提示字符串，不是另一个 MCP 工具。

不要因为 `updated_at` 暂时不变、`recent_activity` 为空或任务较安静就推断失败；按 `get_task` 返回的 `wait_policy` 继续轮询，终态才是权威结果。

OpenCode 的 `steer_task` 和 `interrupt_task` 使用 `get_task` 返回的 `provider_run_id` 填入 `expected_turn_id`：

```json
{
  "task_id": "<任务 ID>",
  "expected_turn_id": "<provider_run_id>",
  "input": "继续处理剩余测试，并优先修复编译错误。"
}
```

Bridge 会在同一个 ACP Session 中把 steer 内容排队为后续 prompt；中断会优先处理并丢弃尚未执行的 steer 队列。

## 7. 权限和数据隔离

- Bridge 的 Plan/Build 只映射 OpenCode 的原生执行模式，不会伪造或绕过 OpenCode 权限。
- OpenCode 继承用户 `HOME` 和 `PATH`，使原生配置与本机工具可用；Bridge 仅隔离每次运行的 cache、state、runtime，并将会话数据库保存在 Service 私有 AgentState。
- Bridge 不读取或回传 OpenCode auth 文件、Token、Cookie 或 Runtime Key。
- OpenCode ACP 的权限请求由本机 Bridge 工作台处理；远程 ChatGPT/Qwen 客户端不能代替本机用户批准。

## 8. 常见问题

| 状态或问题 | 处理方式 |
|---|---|
| 没有可用安装 | 在连接页连接自动发现的候选，或重新登记绝对路径下的真实 CLI 并 Probe，确认已启用。 |
| `needs_review` /“需复核” | 二进制身份发生变化；确认来源可信后点击“接受替换并 Probe”。 |
| ACP 不兼容 | 查看 Probe 返回的具体协议、握手或能力缺口；升级或回退到仍能通过当前 Probe 的 OpenCode 官方版本。文档不预设固定版本范围。 |
| 模型列表为空 | 先连接并启用 OpenCode，选择真实项目，再点击“刷新模型列表”；目录必须来自 ACP。 |
| 模型不可用 | 使用 ACP 返回的精确 ID，不要使用跨 Provider 别名；重新刷新当前安装的目录。 |
| 网络工具被 Provider 拒绝 | 在任务中显式设置 `network_access=true`，并检查 OpenCode 自己的 Provider 和权限配置。 |
| `awaiting_local_approval` | 打开 Bridge 工作台批准任务；ChatGPT/Qwen 无法代替本机批准。 |
| `project_busy` | 等待同一项目的其他写任务或 Direct 操作完成。 |
| `unknown` | 检查 Service/Provider 是否重启；不要自动伪造恢复或启动新任务。 |
| 下载的 App 无法直接打开 | Finder 中对 App 使用“右键 → 打开”，或到“系统设置 → 隐私与安全性”选择“仍要打开”。发布包未配置 Developer ID，也未公证。 |

移除登记只会删除 Bridge 的本地安装记录，不会删除 OpenCode 可执行文件、登录状态或 OpenCode 自己的配置。

## 9. 官方参考

- [OpenCode 官方文档](https://opencode.ai/docs/)
- [OpenCode ACP](https://opencode.ai/docs/acp/)
- [Codex Bridge 详细使用指南](./USER_GUIDE.md)
