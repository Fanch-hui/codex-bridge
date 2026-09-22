# ChatGPT 与 Secure MCP Tunnel 配置指南

适用于 Codex Bridge v1.1.2 的 macOS 与 Windows 版本。完成顺序：创建 Tunnel 并选择 WORKSPACES → 创建 Runtime API Key → 在 Bridge 启动连接 → 在 ChatGPT 创建 App → 提交第一项任务。

## 1. 准备 Bridge

1. 从 [Releases](https://github.com/yeyuancc0-glitch/codex-bridge/releases/latest) 安装对应平台版本。
2. 打开 App，在概览中确认后台 Service 已连接。
3. 在“项目”添加一个本地目录并允许读取。
4. 在工作台选择该项目和 `Read Only`。
5. 在“连接”确认 Secure MCP 隧道的 Helper 显示“就绪”。发布安装包已包含 Helper。

Bridge 自动运行随包 `tunnel-client`，并把收到的请求转发给本机 MCP 服务。正常使用不需要另开终端运行 Helper。

## 2. 区分三个凭据

| 内容 | 获取位置 | 使用位置 |
| --- | --- | --- |
| Tunnel ID | OpenAI Platform 的 Tunnels 页面 | Bridge 的 Tunnel ID；ChatGPT 的 Tunnel 连接 |
| Tunnel Runtime API Key | OpenAI Platform 的 API Keys 页面 | Bridge 的 Runtime Key 输入框 |
| DeepSeek API Key | DeepSeek 或所用模型服务商平台 | Bridge 的 DeepSeek Harness 连接配置 |

Qwen 配置中的本地 MCP 凭据由 Bridge 生成，和这三项不同。ChatGPT Tunnel 连接不需要填写 Qwen JSON 或本地 MCP Token。

## 3. 创建 Tunnel

1. 登录 [OpenAI Platform](https://platform.openai.com/)，切换到准备使用的组织。
2. 打开 [Tunnels](https://platform.openai.com/settings/organization/tunnels)。
3. 创建 Tunnel，填写便于识别的名称，例如 `Codex Bridge`。
4. 在 Tunnel 的 **WORKSPACES** 中选择你实际使用的 ChatGPT 工作区并保存；个人空间选择 **Personal**，团队使用则选择对应的工作区。**这一项需要明确选择，不能留空。**
5. 复制 Tunnel ID，保留给 Bridge 和 ChatGPT 使用。

**已创建 Tunnel，但 ChatGPT 插件的隧道列表里找不到？先检查 WORKSPACES。** 打开 Platform 的 Tunnels 页面，编辑该 Tunnel，在 **WORKSPACES** 中选中目标工作区并保存，再返回同一工作区的 ChatGPT Plugins/Apps 页面，刷新页面或重新打开 Tunnel 选择列表。仅创建 Tunnel、或 Bridge 已显示 `ready`，都不代表已完成工作区关联。

创建和编辑 Tunnel 需要 Tunnels **Read + Manage**；运行 Helper 和在 ChatGPT 选择 Tunnel 需要 **Read + Use**。若入口不可用，由组织管理员检查角色权限。只关联 Platform 组织，可能无法在目标 ChatGPT Workspace 找到它。依据：[OpenAI Secure MCP Tunnel 官方指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)。

Bridge 接受 `tunnel_` 后跟 32 个小写字母或数字的 ID。请复制平台实际值。

## 4. 创建 Runtime API Key

1. 在同一组织打开 [API Keys](https://platform.openai.com/settings/organization/api-keys)。
2. 创建新的运行时 API Key，权限选择 **Restricted**。
3. 在 Tunnels 权限中启用 **Read** 和 **Use**。
4. 创建后复制 Key，直接粘贴到下一节的 Bridge 输入框。

管理 Tunnel 的 Admin API Key 与日常运行的 Runtime Key 用途不同。Bridge 输入的是 Runtime Key。Key 如被撤销，应在平台创建新 Key，再回 Bridge 保存。

## 5. 在 Bridge 启动连接

1. 打开“连接 → 远程 AI 客户端 (OpenAI Secure Tunnel)”。
2. 在 **Tunnel ID** 粘贴实际 ID。
3. 在 **Runtime Key** 粘贴刚创建的 Key，保持内容完整且没有额外引号、空格或换行。
4. 点击“保存并启动连接”。
5. 等待状态为 `ready`，并确认“远程任务接收”为“允许”。

Runtime Key 由后台 Service 存入 macOS Keychain 或 Windows Credential Manager。提交后输入框清空是正常行为；已保存密钥不会重新回显到页面。

| 页面状态 | 下一步 |
| --- | --- |
| Helper 未打包 | 使用包含 Helper 的正式安装包 |
| `starting` / `authenticating` / `connecting` | 等待连接，必要时查看日志中的诊断 |
| `ready` 且远程任务接收允许 | 继续配置 ChatGPT |
| `degraded` | 临时连接异常，Service 会按退避策略恢复 |
| 需要检查凭据 / `failed` | 检查 Key、组织、Tunnel ID 和网络诊断 |
| `stopped` | 需要使用时点击重新连接 |

“Helper 就绪”只说明组件可用；以 Tunnel `ready` 和接收状态判断连接结果。主动断开会停止重连。“清除配置”清除本机配置和密钥，平台上的 Tunnel 与 API Key 仍由平台管理。

## 6. 在 ChatGPT 创建连接

> [!NOTE]
> ChatGPT 需要有 Plus 及以上订阅或团队订阅才可以使用 Developer mode 与 Secure MCP Tunnel（免费版账号不提供开发者模式入口）。实测订阅用户都可以使用完整权限的 MCP。

1. 打开 ChatGPT 设置，在 **Security and login** 中启用 **Developer mode**。
2. 打开 Plugins/Apps 管理页面，点击加号创建 developer-mode App。
3. 连接类型选择 **Tunnel**。
4. 选择刚创建的 Tunnel，或粘贴与 Bridge 相同的 Tunnel ID。
5. 完成工具扫描并保存。
6. 新建对话，从加号菜单的 Developer mode 中选择这个 App。

这是当前官方入口；受管 Workspace 还需管理员授予开发者模式权限。实测订阅用户都可以使用完整权限的 MCP（包括工具发现、`bridge_status` 查询与 `submit_task` 执行）。入口随账号与网页版本变化，以 [OpenAI Developer mode 文档](https://developers.openai.com/api/docs/guides/developer-mode) 为准。

Tunnel 表单使用 Tunnel ID，不填写本机 `127.0.0.1` 地址。Runtime Key 只保存在 Bridge。若表单只有公共 MCP URL，返回连接类型选择 Tunnel。

## 7. 第一次调用

先在 ChatGPT 输入：

```text
请使用 Codex Bridge 调用 bridge_status，然后列出已登记项目和可用 Agent。先不要修改文件。
```

确认能返回真实项目后，在 Bridge 选好项目、Agent 和 `Read Only`，再输入：

```text
请通过 Codex Bridge 的 Codex Agent 检查当前项目 README，总结项目用途，不修改文件。
```

默认远程任务会等待本机批准。在 Bridge 工作台核对项目和任务内容，点击批准，查看实时输出。运行中若出现工具审批或结构化问题，在工作台处理；批准启动与执行期审批各自独立。

若希望使用 DeepSeek Harness，请明确说“使用 DeepSeek Harness”，客户端应发送 `provider_id=deepseek-harness`。先按 [DSH 配置指南](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) 完成连接。

Bridge 为 ChatGPT 和 Qwen 默认提供完整工具目录，包括 `submit_task`；实测订阅用户都可以使用完整权限的 MCP，实际执行仍服从项目策略和审批。工具目录变更或 App 更新后，请在 ChatGPT 刷新 App/重新扫描工具。

## 8. 版本更新后在 ChatGPT 刷新插件（防旧版缓存）

Codex Bridge 升级新版本后，ChatGPT 网页端可能会保留旧版的工具列表、提示词或会话缓存。为确保加载最新工具与指令，每次更新后建议按以下步骤刷新一次：

1. **重新扫描/刷新工具**：
   - 打开 ChatGPT，进入 **Settings → Security and login → Developer mode**（或在输入框加号菜单中找到 Codex Bridge App 详情）；
   - 点击该 App，选择 **Refresh tools**（刷新工具）重新拉取最新的 MCP 工具定义与描述。
2. **新建对话加载**：
   - 关闭旧对话，点击左上角 **New Chat**（新建对话）；
   - 在输入框左下角加号（`+`）菜单中重新选择 Developer mode 下的 Codex Bridge App；
   - 发送一条测试指令（如：`请调用 bridge_status 查看当前状态`），确认加载的是最新版本。
3. **彻底重新挂载（可选）**：
   - 若 ChatGPT 持续返回旧参数或未识别新工具，可在 App 管理中先删除该 App，再点击加号选择相同的 Tunnel ID 重新添加并完成工具扫描。

## 9. 常见问题

| 问题 | 检查与处理 |
| --- | --- |
| 看不到 Tunnels 或无法创建 | 确认 Platform 组织及 Read + Manage 权限 |
| 已创建 Tunnel，但 ChatGPT 插件的隧道列表中找不到 | 优先检查 Platform → Tunnels → 编辑该 Tunnel → **WORKSPACES** 是否已选中并保存。个人空间选择 **Personal**，团队选择对应工作区；回到同一工作区的 ChatGPT 刷新列表。仍不可见时，再检查 Read + Use 权限 |
| 找不到 Developer mode | 确认账号是否拥有 Plus 及以上或团队订阅（免费版账号不提供开发者模式入口）；受管 Workspace 需检查账号权限和管理员设置 |
| 保存时报配置无效 | 重新复制 Tunnel ID；Key 不加引号或空白 |
| 一直认证失败 | 确认 Key 所属组织、Read + Use 权限、是否撤销；查看 Bridge 日志 |
| 连接失败或反复掉线 | 检查本机到 OpenAI 的出站 HTTPS 与代理配置；查看 Tunnel 诊断 |
| Bridge ready，但扫描失败 | 保持 Service 运行，核对两端 ID、Workspace、连接类型 |
| 工具能扫描但没有执行任务 | 在当前对话选择 App，明确要求调用；刷新工具目录 |
| 更新后工具未生效或仍使用旧参数 | ChatGPT 网页端保留了旧版工具缓存；按第 8 节说明在 ChatGPT 刷新工具并新建对话 |
| 任务等待本机审批 | 在工作台批准启动或处理当前工具权限请求 |
| 任务长时间没有新文本 | 查看活动与审批状态，按客户端返回的等待策略继续查询 |
| 更换电脑后不能连接 | 在新电脑安装 Bridge，并用该电脑自己的项目配置与系统凭据重新连接 |

## 10. 后续使用

- 查询任务结果时，客户端按 `get_task.wait_policy` 等待，并从 `get_task` 读取结果摘要与状态。
- Tunnel 暂时断线不等于本机任务失败；恢复后可继续查询。
- 本机工作台可直接提交任务，不依赖 ChatGPT Tunnel。
- 使用与项目权限、Qwen、模型选择相关的完整流程，见 [详细使用指南](./USER_GUIDE.md)。
