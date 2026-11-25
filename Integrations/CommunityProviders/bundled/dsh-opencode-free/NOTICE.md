# NOTICE：来源与适配说明

本包（`dsh-opencode-free`，上游版本 `0.6.0`）源自开源项目
[x5427876/dsh-opencode-free](https://github.com/x5427876/dsh-opencode-free)
（npm tarball `https://registry.npmjs.org/dsh-opencode-free/-/dsh-opencode-free-0.6.0.tgz`，
SHA-512 `l20oFokgSb1/Fq1tsqgVvksr6gmqfv41uqzGTE79McNsvHev9B4PUubzHpR+aRIzrz3qk0S+fKbq86X73y5vYQ==`），
以 MIT 协议发布。**与上游项目、OpenCode 及 DeepSeek 均无隶属关系。** 上游 [LICENSE](LICENSE) 原样保留。

## Codex Bridge 适配说明（`0.6.0-bridge.1`）

上游 `lib/zen.js`、`lib/zen-tls.js`、`lib/zen-provider.js`、`lib/catalog.js`、`README.md` 与
`README.zh-TW.md` 保持原样以便对比同步。仅移除不适用于社区插件宿主的 DSH Cordis / React / pi-ai
文件（`AGENTS.md`、`cordis.patch.yml`、`src/client.js`、`lib/index.js`、`lib/adapter.js`、
`lib/config.js`、`lib/pi-*.js`、`lib/types/`），并将适配逻辑集中在四个独立模块中：

| 编号 | 位置 | 说明 |
|---|---|---|
| B1 | `package.json` | 版本改为 `0.6.0-bridge.1`，入口指向 `./bridge-opencode.mjs`，移除 DSH 专用依赖声明，补充 `magpie.maxConcurrency: 2` |
| B2 | `bridge-opencode.mjs` | 实现 OpenCode / Magpie 社区供应商宿主接口（`provider: dsh-opencode-free`、`single: true`）；提供「个人 OpenCode Zen API Key」与「免费匿名访问（public）」两种连接方式；Bun 运行时直接走 `globalThis.fetch` 以保留宿主代理与重定向隔离，Node 环境下按需使用 `lib/zen-tls.js` |
| B3 | `bridge-catalog.mjs` | 直接解析官方 `/inference/v1/models` 免费模型列表并映射为网关模型元数据（含多模态输入、推理强度档位与 Chat / Responses / Anthropic 协议通道），不依赖 `@earendil-works/pi-ai`；目录缺失或模型未列入免费目录时拒绝发往上游（防止误扣个人 Key 付费额度） |
| B4 | `bridge-gate.mjs` | 为匿名 `public` 请求提供 OpenCode CLI 请求头、48 位降序时间编码 `ses_` 会话亲和、`<env>` 块、摘要提示词替换、工具别名（`subagent_fork`/`working_directory`/`pwsh`）与不可执行占位声明；个人 Key 请求不改写工具或提示词；支持 `400 encrypted_content` 单次去历史推理重试 |
| B5 | `bridge-response.mjs` | 拦截任何模型返回的未授权占位工具调用（`unavailable_admission_tool`），还原工具别名与参数名，并在客户端请求 `stream: false` 时将强制流式的匿名 SSE 响应折叠为标准 JSON |
| B6 | `NOTICE.md` | 记录上游来源、保留文件、移除文件及全部适配改动 |
