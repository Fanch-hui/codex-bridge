# Gemini Cloud MCP · ChatGPT Sites 模板

公开 Site 接收 Gemini 的 MCP 请求，本机 Codex Bridge 主动领取并执行，再回传结果。无需开放本机入站端口；Bridge 必须保持运行。每个 Site 连接一个 Bridge。

Gemini 网页版（包括 Bridge 内置浏览器）必须使用 Cloud MCP，可通过本模板部署的 Sites 或 ngrok 接入。本地 MCP 启动命令仅用于与 Bridge 同机、能启动本机程序的 Gemini 桌面 App。

**本方式需要可使用 ChatGPT Sites 的账号，无需配置 OpenAI Platform、Tunnel ID 或 OpenAI Runtime API Key。** `BRIDGE_MCP_KEY` 和 `BRIDGE_RELAY_KEY` 均由 Bridge 生成，用于站点访问与请求回传，与 OpenAI Runtime API Key 无关。本地 MCP 或 ngrok 方式无需使用 ChatGPT Sites。

## 让 Codex 帮你配置

准备可使用 ChatGPT Sites 的账号，并在 Bridge 的「连接 → Gemini」启用 Gemini，在「云 MCP」选择「ChatGPT Sites（公开）」。将下面的完整提示词复制给有 Sites 部署能力的 Codex：

```text
请帮我部署 Codex Bridge 的 Gemini Cloud MCP 转发站点。

请从公开仓库 https://github.com/Fanch-hui/codex-bridge 的 win 分支取得 Integrations/GeminiSites 完整模板，并先阅读该目录的 README。按模板创建一个新的 ChatGPT Sites 站点并公开部署，保留真实的 MCP 请求转发、D1 队列，以及本机 Bridge 主动领取请求和回传结果的接口。使用模板自己的构建脚本，不要用只有演示工具或静态页面的站点代替。

我会另行通过受保护的 Secret 配置方式提供 Bridge「复制 Sites 托管配置」中的两项值。请将 BRIDGE_MCP_KEY 和 BRIDGE_RELAY_KEY 分别设置为站点运行时 Secret；缺少配置时提示我完成 Secret 设置。不要将它们写入源码、hosting.json、公开网页、日志或回复，也不要在回复中输出含密钥的 Gemini 连接链接。

部署完成后，请返回站点的 HTTPS 根地址和部署结果，方便我填回 Bridge。随后告诉我：在 Bridge 保存该根地址并启用云 MCP，等待连接成功，再从 Bridge 复制完整连接链接，到 Gemini 的「更多 → 自定义 → 关联应用 → 右上角『＋自定义』」选择 Cloud MCP，粘贴完整连接链接并将 OAuth 高级选项留空；点击下一步，核对工具列表、将应用名称填写为 Codex Bridge，然后完成关联。Gemini 只有在任务模式下才能使用已添加的自定义 MCP。完成关联后，在 Gemini 中切换到任务模式，启用 Codex Bridge 应用，再调用 bridge_status 和 list_projects 检查连接。
```

按提示将 Bridge「复制 Sites 托管配置」中的两项值另行填入受保护的 Secret 配置入口。部署后，将 Codex 返回的 **HTTPS 根地址**保存到 Bridge 并启用云 MCP；连接成功后，点击「复制 Gemini 专用链接」。

在 Gemini 打开 **更多 → 自定义 → 关联应用 → 右上角「＋自定义」**，选择 **Cloud MCP**，地址填写 Bridge 生成的**完整专用链接**，高级 OAuth 配置无需填写。点击「下一步」，核对工具列表，将应用名称填写为 `Codex Bridge`，然后完成关联。**Gemini 只有在「任务模式」下才能使用已添加的自定义 MCP。** 切换到任务模式并启用 Codex Bridge 应用，再让 Gemini 调用 `bridge_status` 和 `list_projects` 检查连接。

HTTPS 根地址用于 Bridge 配置，完整专用链接用于 Gemini；不要用根地址代替 Gemini 的连接链接。完整的本地 MCP、Sites 与 ngrok 操作见[使用指南](../../docs/USER_GUIDE.md#82-连接-gemini-云-mcp)。

## 开发者：模板配置与发布

模板位于公开仓库 [Fanch-hui/codex-bridge 的 win 分支](https://github.com/Fanch-hui/codex-bridge/tree/win/Integrations/GeminiSites)。每个 Site 对应一个 Bridge，必须使用完整转发模板；只有演示工具或静态页面的站点无法转发本机工具。

1. 在 Bridge 的「连接 → Gemini → 云 MCP」选择「ChatGPT Sites（公开）」。
2. 将此目录作为 Sites 的保留 Worker ESM 模板创建新 Site，并设为公开。通过 Sites 官方 `project-setup.mjs --starter worker-esm --template-source <本模板绝对目录>` 准备独立 checkout；创建 Site 后用 `set-project-id.mjs --project-id <新 Site ID>` 写入该 checkout 的身份。
3. 在 Bridge 点击「复制 Sites 托管配置」，把 JSON 中的 `BRIDGE_MCP_KEY`、`BRIDGE_RELAY_KEY` 分别设置为 Sites 运行时 Secret。二者均为独立的 64 位十六进制字符串，不能相同；不要写入源码、hosting.json、公开网页、日志或回复。
4. 使用 `node scripts/build.mjs` 构建。Sites 官方 source workflow 的 `commands` 使用 `[["node", "scripts/build.mjs"]]`，再按官方流程保存版本并公开部署。`.openai/hosting.json` 保持 `"d1": "DB"`；构建产物包含 D1 迁移，部署时由 Sites 应用。
5. 把部署后的 **HTTPS 根地址**保存到 Bridge，启用云端连接；连接成功后，复制 Bridge 提供的完整专用链接，按上面的 Gemini 流程完成关联。

Site 首页公开不代表工具无权限开放。MCP 专用链接包含访问密钥，持有完整链接即可请求 Gemini 客户端获准使用的工具，项目目录、Direct 规则和本机审批仍由 Bridge 执行。请按凭据保管链接，不要贴到公开页面、Issue、日志或对话回复中。Bridge 后台服务需保持运行。

重置 Gemini 凭据会使旧链接失效。重新复制「Sites 托管配置」，同步更新站点的两项运行时 Secret，再重新复制完整连接链接并更新 Gemini。队列按两项密钥共同派生的摘要隔离，更新后的 Bridge 不能领取或完成旧链接发起的请求，旧代请求也不占用新代队列容量。

## 接口

| 接口 | 认证与行为 |
| --- | --- |
| `POST/DELETE /gemini-mcp/<BRIDGE_MCP_KEY>` | 使用完整链接访问，转发至 Bridge；GET 返回 405 |
| `POST /api/bridge/poll` | `Authorization: Bearer <BRIDGE_RELAY_KEY>`；请求 `{limit:1..4}`，返回 `{requests:[{id,method,headers,body}]}` |
| `POST /api/bridge/complete` | 同上；请求 `{id,status,headers,body}`，成功返回 204，重复结果幂等 |
| `GET /` | 公开用途说明 |

`body` 是标准 Base64。`/mcp` 不提供工具，也不触发 OAuth 发现。请求头仅转发 `content-type`、`accept`、`mcp-session-id`、`mcp-protocol-version`、`mcp-method`、`mcp-name`、`last-event-id`；响应仅转发 `content-type`、`mcp-session-id`、`mcp-protocol-version`。

队列最多容纳 16 个未交付请求；一次最多领取 4 个。请求被原子领取后不会再次派发，Bridge 断线时由调用方得到超时结果；可能改变状态的操作应先查询实际结果。外部请求最多等待 310 秒，记录在 320 秒后由后续请求清理。请求正文上限 1 MiB、响应正文上限 8 MiB，响应按块保存以适应 D1 单字段限制。通知的 202 结果保持原样。

## 本地验证

使用 Node.js 22.13 或以上版本，无需安装依赖：

```sh
node --test Tests/relay.test.mjs
node scripts/build.mjs
```

测试使用内置 `node:sqlite` 执行生产 SQL，覆盖队列上限、原子领取、超时、分块结果、幂等回传、请求头过滤和完整 Worker 转发。`node Tests/server.mjs` 提供仅回环的测试 HTTP 服务，首行输出随机端口；测试访问密钥为 64 个 `1`，回传密钥为 64 个 `2`，仅用于本机集成测试。
