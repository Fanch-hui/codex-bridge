# 本机 Agent 使用 Bridge 模型

v3.1.0 有两种用法：**在 Bridge 工作台聊天**，直接在输入框选择已连接的供应商模型；**在其他本机 Agent 中聊天**，则把它作为应用接入 Bridge 的本机回环网关。后者使用该应用独立的凭据，只能调用为它勾选的 Bridge 模型，不需要创建工作台会话。

## 接入一个本机应用

1. 在侧栏「供应商」连接账号。社区供应商从「插件目录」安装，按插件的「使用指南与详情」完成首次连接；使用 ChatGPT 登录模型时，在 ChatGPT 账号设置中勾选「允许外部 Agent 调用 ChatGPT 模型」。
2. 到「接入应用 → 已接入应用 → 连接应用」，选择「目标应用」；选「其他应用」时填入「应用名称」。新建授权默认勾选目录中的模型，在「允许使用的模型」只保留要分享的模型。目录为空时点「连接供应商」，连接后回到此处点「刷新模型目录」。
3. **模型授权不是项目授权。** 只用模型时不用启用 MCP。需要通过 Bridge 调用项目工具时，展开「高级设置 → MCP 授权」，勾选「允许使用 Bridge MCP」并选择「允许访问的项目」。如需命令工具，再勾选对应选项；命令仍受审批策略约束。也可以只授权 MCP，不选模型。
4. 按下表选择写入或手动配置。选了模型时，保存会按需启动网关。Codex CLI 和 Claude Code 的官方登录共存选项默认关闭，要共存请在写入前勾选。配置完成后在目标应用中开始新会话，桌面版按表中说明重启。

自动写入的变更列在「已应用的配置」：点对应记录的「撤销配置」可撤回该次写入。「已接入应用」里的「撤销」则是让这个应用的访问凭据失效；两者不是同一个操作。

## 按目标应用配置

| 接收模型的应用 | 如何使用 | 边界 |
| --- | --- | --- |
| Codex CLI | 写入默认模型，使用 Responses 接口；勾选「保留官方登录态共存」时改为写入 `profiles.codex_bridge`，不改动默认供应商，命令行运行 `codex -p codex_bridge` 即可与官方 `codex` 并行使用 | 原生选择器另有模型目录格式；授权列表不会自动变成完整的 Codex 目录。 |
| Codex 桌面版 | 写入全局 `~/.codex/config.toml`（Responses 接口），写入后重启 Codex 桌面版生效；想用回官方登录时点「撤销配置」即可还原 | 只读取全局配置，不支持在界面内切换 profile，不提供「保留官方登录态共存」；原生选择器另有模型目录格式。 |
| Claude Code (CLI) | 默认写入网关和默认模型；支持 modelPicker 的版本会在全局列表加入其余选中模型。勾选「保留官方登录态共存」时，使用网关地址与 `X-Codex-Bridge-Token`，不覆盖官方登录态；在 `/model` 选 Bridge 模型走本机网关，选官方 Claude 模型则透传至 `api.anthropic.com` | 老版本使用默认模型。跨协议时不能保留 Anthropic 服务端工具或签名思考；流式用量尚未收到时为 null，要求整数字段的客户端可能拒绝。 |
| Claude 桌面版 | 保存授权后点「复制 3P 网关配置」，在 Claude 桌面版打开 `Help → Troubleshooting → Enable Developer Mode`，再进入 `Developer → Configure Third-Party Inference…` 导入或填写并重启；若勾选 MCP，保存时自动写入 `claude_desktop_config.json` | 加密保存第三方网关配置，不支持外部直接写入模型；开启 3P 推理模式后无法同窗口保留 `claude.ai` 登录态。跨协议时不能保留 Anthropic 服务端工具或签名思考。 |
| OpenCode 1、2 | 按版本写入供应商和所有选中模型 | 两代配置格式不同，请选实际使用的版本。 |
| Pi | 写入全局 models.json，在 /model 中选择；MCP 单独写入 mcp.json | 使用 Pi 配置目录；嵌入式 SDK 的扩展由其宿主决定。 |
| Qoder | 选「其他应用」，保存授权后复制配置，在桌面版的自定义模型界面添加 | CLI 由 Qoder 自己的 BYOK 向导管理。 |
| Antigravity | 选「其他应用 → 保存授权 → 复制接入配置」。在提供企业网关设置的版本使用 OpenAI 协议、回环根地址（去掉 `/v1`）和已授权的模型 ID | 只支持 Gemini 协议的 ACP 客户端无法接入。 |
| 独立运行的 DeepSeek Harness | 选「其他应用 → 保存授权 → 复制接入配置」，在其 llm-pi-ai 供应商配置中填写兼容地址和独立应用凭据 | Bridge 内置工作台已直接复用供应商，不需要配置回环。 |

## 在 Bridge 工作台中使用

在「供应商」安装社区插件即可启用。OpenCode Zen Free 0.1.28 会自动建立公开访问；私人供应商首次需要按插件要求授权，已保存的账号会复用。模型目录同步后，在工作台输入框的模型选择器中选择模型即可。关闭对外模型网关不影响工作台；停用插件会撤下它的模型。工作台关闭时，供应商变化不会启动它。

## 供应商限制

社区插件的固定版本、登录方式和模型协议可在「供应商」中查看，操作说明见对应插件的「使用指南与详情」。可载入插件、能列出模型和真实账号有额度，是三个不同的条件。

- ChatGPT SIWC 的采样和输出上限由服务管理；WorkBuddy 的严格工具以及会改变含义的工具参数结构、ZCode 的严格工具和结构化输出会明确报错。ZCode 的额度耗尽会作为额度错误返回。
- Qoder、Cursor、Devin、Trae、Command Code 以及 Providers Hub 的部分渠道会重新构造请求。网关按插件版本和渠道处理工具选择、图片、停止条件及采样参数。Cursor、Devin、Accio 使用内嵌图片；Trae 只向明确支持图片的模型传图。Devin 的 Claude 路径无法保证保留签名推理历史。Trae、Loomy 等插件依模型的实时档位决定推理强度。
- Kiro 仅支持纯文本 Chat / Responses；Muse 的工具及历史引用有限制。Zed、Factory 中使用 Gemini 原生协议的模型不在可用列表。Grok、AWS Bedrock SSO、TeleAgent 均可直接安装，按插件内「使用指南」配置好本机对应的 CLI 或桌面端登录态后即可连接使用。
- 跨协议时，指定停止词无法转成 Responses；仅有历史响应编号的续写需要客户端提供完整对话。HTTP Warning 会列出由服务托管的参数。Chat / Responses 的缓存和推理用量明细在部分转换中仍可能将缺失值显示为零，不能据此判断计费。

原生配置依据：[Claude Code 模型选择器](https://code.claude.com/docs/en/settings-reference#modelpicker)、[Pi 模型](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)、[Pi MCP](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md)、[Qoder 自定义模型](https://docs.qoder.com/qoder/custom-models)、[Antigravity 企业网关](https://docs.cloud.google.com/gemini/enterprise/docs/ai-developer-tools/deploy-enterprise-gateway)、[DSH 供应商配置](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-pi-ai/README.md)。
