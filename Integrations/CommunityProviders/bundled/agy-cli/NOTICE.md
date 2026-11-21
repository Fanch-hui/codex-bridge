# NOTICE：来源与合规说明

本包（`@magpie-community/opencode-agy-cli-auth`，版本 0.1.0）源自 Antigravity 桥接插件
`opencode-antigravity-bridge`，由 gitxm 整理为 `gitxm/yce-magpie-agy` 后提交到
magpie-community/plugins（plugins#785），以 MIT 协议发布。**与上游无隶属关系。** 上游版权声明原样保留在 [LICENSE](LICENSE)，
本仓新增部分的版权归 gitxm 与 yce。

## 1. 包与标识

| 项目 | 取值 |
|---|---|
| npm 包名 | `@magpie-community/opencode-agy-cli-auth` |
| 版本 | `0.1.0` |
| 仓库 | `https://github.com/magpie-community/plugins`（`packages/agy-cli`） |
| Magpie provider ID | `agy-cli` |
| 安装 | `magpie plugin add @magpie-community/opencode-agy-cli-auth` |
| 原始仓库 | `https://github.com/gitxm/yce-magpie-agy`（包名 `@magpie-community/yce-magpie-agy`、provider ID `yce-magpie-agy`，均未发布到 npm） |

进程内部标识保持不变，以免影响已有的状态文件与日志：`AGY_BRIDGE_*` 环境变量、
`magpie-agy-bridge/` 状态与临时目录、`[agy-bridge]` 日志前缀、导出名 `AntigravityBridgePlugin`。

## 2. 来源基线

| 基线 | 版本指纹 | 说明 |
|---|---|---|
| 上游主干 | `DylanLIiii/opencode-antigravity-bridge@7e13b127a62e8eaa41d8de2d3eedd8afe1cfd4eb` | 上游 main 的 HEAD |
| PR #8 基线（代码底稿） | `gitxm/opencode-antigravity-bridge@acb8d84c5136d18889d7d4b91f119117b57abb74` | 分支 `fix/windows-bg-updater-popup`，父提交为上游 `7e13b12`；包含 `platform.mjs`、Windows 无弹窗修复与多步用量结算 |
| 本机补丁（`index.mjs`） | `index.mjs.patched`，md5 `38aa8d42f3e76a2536d11be63b5807a5` | 基于上游 `212179f` 的本机补丁版 |
| 本机补丁（`usage.mjs`） | `usage.mjs.patched`，md5 `df212a2c934ffd4a38d7f3ef95271c5d` | 基于上游 `7e13b12` 的本机补丁版 |

合并原则：代码以 PR #8（`acb8d84`）为底。本机补丁中 `acb8d84` 没有的修复，按下面的
A1–A16、U1–U6 逐项并入。两边都有、且 `acb8d84` 写法更新的部分（多步用量结算、
`requestedEffort`、`withStateLock`、`lineageVerdict`、`matchToolResults`、`inspectToolTurn`
等）保留 `acb8d84` 的实现，不搬运补丁版代码。

## 3. `index.mjs` 并入的修复（A1–A16）

| 编号 | 内容 |
|---|---|
| A1 | 模型目录缓存：TTL 5 分钟；首次最多等 500 ms，超时先返回旧目录，后台单飞刷新；刷新失败保留上次成功结果；启动时先用 `FALLBACK_MODELS` 预热。`provider.models()` 不再每次强制执行 `agy models` |
| A2 | `listAgyModels` 在报错、超时、退出码非 0 或输出为空时返回 `null`，不再用兜底列表覆盖动态目录 |
| A3 | `execOnce` 超时立即 resolve（带 `timedOut`），子孙进程占着管道也不会挂起；后台刷新路径的计时器 `unref()`，前台调用保持 ref |
| A4 | 为 `gpt-oss-120b` 补充指向 medium 的裸名别名 |
| A5 | `modelLimits(id)`：`provider.models()` 输出每个型号的 `limit`（上下文与输出上限），与 `capabilities` 并存 |
| A6 | `findAgy` 缓存键包含 `AGY_PATH`、`PATH`/`Path`、`LOCALAPPDATA` 与 home 目录，环境变化时重新查找 |
| A7 | 无进展重复上限：同一无进展回合连续收到对不上的工具结果，前两次返回 409，第三次强制回收并重放；重放不了则返回终止性 400。`recoverStaleTurn` 区分 active、conflict、incomplete、replayed、fallthrough 五种情况 |
| A8 | `jsonError(status, message, code, { extra, headers, noRetry })`，支持把 `extra` 并入 error 对象（A7 依赖它） |
| A9 | 工具调用 30 ms 合批：相邻事件循环里到达的 MCP 调用合并到同一次响应；`Turn.next` 带等待者清理；按 `emittedIds` 去重；文本与结束事件的边界不合并 |
| A10 | `canonicalBody` 只提取开头连续的 `role=system` 消息（沿用上游 `acb8d84` 规则），保证 Claude Code 尾随的 system 通知不会触发第二轮重建会话；同时并入 `contentText`、`requestLayout`、`noteLayout` 布局追踪 |
| A11 | 诊断事件限流（60 秒窗口最多 30 条，附 `suppressed` 计数）；请求级 `req_id`；冲突事件输出 `idle_ms` 与 `pending`；过期原因细分为 finalized、dead、done、running；`layout_flip` 只在 `AGY_BRIDGE_EVENTS=verbose` 时输出 |
| A12 | `Turn.rawAcpUsages` 保存每个已记账 prompt 的原始 ACP usage 对象 |
| A13 | `addUsage` 通过 `tokenCount` 把累加结果限制为非负整数 |
| A14 | `reclaimStaleTurn` 同时清除该会话的无进展重复计数 |
| A15 | 防止 503 进程池饿死：并发上限默认值由 8 改为 16（`AGY_BRIDGE_MAX_PROCS`，`magpie.maxConcurrency` 同为 16）。`evictLRU` 分两级淘汰，第二级淘汰客户端已断开超过 30 秒（`AGY_BRIDGE_DETACHED_EVICT_MS`）的挂起工具回合，之后补交的合法 `tool_result` 会在新进程上重放。`acquireProcLocked` 遇到同会话旧回合时先判断过期并回收。历史压缩后变短的新请求判为 fork，回收旧回合 |
| A16 | 长历史重放预算：`renderInitialPromptParts` 默认限制在 112 KiB（`AGY_BRIDGE_MAX_PROMPT_BYTES`）内。先为必保段预留预算（system 说明、`</conversation_history>` 闭合标签及禁止输出工具调用声明的文字、完整的 `<current_turn>`），历史按头尾保留，超长的 `[tool result]` 保留首尾、省略中间，保证不被 agy 的 128 KiB 尾部截断切掉 |

## 4. `usage.mjs` 并入的修复（U1–U6）

| 编号 | 内容 |
|---|---|
| U1 | 去掉 win32 上直接报错 `agy bridge usage queries currently require macOS or Linux.` 的限制；接入 `agySpawnSpec`，兼容 `.cmd` 与 `.bat`，使 Windows 上的 `magpie quota` 可用 |
| U2 | `spawn` 只在非 Windows 上使用 `detached`，Windows 上一律 `windowsHide: true` |
| U3 | Windows 进程树清理：先执行 `taskkill /T /F /PID` 清除进程树，只有 `taskkill` 失败或超时才补 `SIGKILL`，避免提前杀掉父进程导致 `taskkill` 漏杀子树。父进程正常退出后延迟 30 ms 再清理进程树；`finish()` 只在出错或子进程仍在运行时清理 |
| U4 | Windows 上拦截浏览器启动：写入内容为 `@exit /b 1` 的 `open.cmd`，并让 `BROWSER` 指向它 |
| U5 | PATH 大小写去重：删除非大写的 `Path` 键，继承 `env.PATH`，没有时回落到 `env.Path` |
| U6 | 临时目录删除遇到 `EBUSY`、`EPERM`、`ENOTEMPTY` 时，先等待在途的 `taskkill` 释放目录句柄，再最多重试 4 次，每次间隔递增 50 ms |

## 5. 包与文档层改动

- 包名改为 `@magpie-community/opencode-agy-cli-auth`，版本 `0.1.0`，`repository` 指向 magpie-community/plugins 的 `packages/agy-cli`。
- `magpie.maxConcurrency` 与 `AGY_BRIDGE_MAX_PROCS` 默认值统一为 16。
- `README.md`、`README.en.md` 整篇重写，`LICENSE` 追加本仓版权行。原仓库的 `HANDOFF.md` 不随包发布。
- `NOTICE.md`（本文件）与 `LICENSE` 一并随包发布。

## 6. 版权

[LICENSE](LICENSE) 保留上游版权行 `Copyright (c) 2026 DylanLIiii`，并依次列出
`Copyright (c) 2026 gitxm` 与 `Copyright (c) 2026 yce`。MIT 正文未作修改。

## 7. 从旧版迁移

旧版是包名 `magpie-agy` 0.2.0，provider ID 为 `antigravity-bridge`。改为 0.1.0 后：

1. **provider ID 变化**：Magpie 中的 provider 变为 `agy-cli`。所有写着旧 ID 的模型名
   （`antigravity-bridge/<模型>`，或从 GitHub 安装 `gitxm/yce-magpie-agy` 时的 `yce-magpie-agy/<模型>`）
   都要改成 `agy-cli/<模型>`，包括路由组和会话里的模型引用。
2. **登录态**：登录状态按 provider ID 记录。切换后需要在新 provider 上重新登录，或者把登录记录改名。
3. **内部状态不变**：会话停车文件仍在 `magpie-agy-bridge/sessions.json`，已有会话可以续接。
4. **切换顺序**：先安装新包，确认新 provider 能返回 200，再逐个改模型名；旧包最后移除。
   本仓内不执行切换操作。

## 8. Codex Bridge modifications

Codex Bridge 以 `0.1.108-bridge.N` 内置本包（上游提交 `c7aca97253`，MIT）。改动集中在三个新增的独立模块
`bridge-workspace.mjs`、`bridge-tools.mjs`、`bridge-agy.mjs`，`index.mjs` 中只保留最少的接入点（均带
`Codex Bridge` 注释），便于与上游对比和同步。**未修改 `cloak.mjs`，没有新增或扩充任何系统提示词改写、身份句过滤或剥离逻辑。**
上游 `install.mjs` 不随本版本分发；`usage.mjs` 中 agy 缺失的提示改为同一段说明。

| 编号 | 位置 | 改动 |
|---|---|---|
| B1 | `package.json` | 版本改为 `0.1.108-bridge.N`（当前 `0.1.108-bridge.2`）（包名不变）；`description` 注明是 Codex Bridge 适配版；`files` 加入三个新模块 |
| B2 | `bridge-workspace.mjs`、`index.mjs`（`Proc.#spawn`、`resumeWorkspace`、`ensureShimDir`、模块末尾的清理启动） | agy 的工作目录从 `os.tmpdir()` 改到会话状态文件（`AGY_BRIDGE_STATE_FILE` 或默认状态路径）所在目录下的 `workspaces/`，权限 0700；该目录不可写时回退到临时目录。续接时同时接受新根目录与旧的临时目录路径，路径名规则不变。`AGY_BRIDGE_WORKSPACE_ROOT` 可指定绝对路径，或设为 `tmp` 回到上游行为。agy 停止时删除工作目录、续接时按原名重建、`reapOnExit` 的清理语义不变；新增每小时一次（启动后 30 秒首轮）的有界清理：只删名字符合插件命名、属于当前用户、既不属于存活的 agy 也不属于仍在 `AGY_BRIDGE_RESUME_TTL_MS` 内的待续接会话、且目录与 `agy-acp.log` 都超过该期限未变化的目录，每轮最多检查 256 个，不跟随符号链接。POSIX 的 `nc` 垫片目录若被系统清理，下次启动 agy 前重新生成 |
| B3 | `bridge-tools.mjs`、`index.mjs`（`stillRunningText`、`renderLateResults`） | 「仍在运行」占位文本更明确：这不是结果也不是错误，不要转做别的、不要换方式重跑，用完全相同的参数再次调用以等待，直到真实结果返回。仍含 `still running`。迟到结果补发末尾追加一句说明这些结果取代之前的占位、不要再次执行。`AGY_BRIDGE_IDE_CALL_DEADLINE_MS` 默认值 150 秒未改；每个调用只在客户端执行一次的机制（按名称与参数匹配已延后的调用）未改 |
| B4 | `bridge-tools.mjs`、`index.mjs`（`toolsUnlistedError`） | 请求带工具而 agy 未经 `nc` 桥接列出工具时，上游已以 502、`tools_not_loaded` 结束请求且不运行回合；仅在 POSIX 的错误消息末尾补充 agy 版本与「agy 更新后启动 MCP 服务器的方式可能变化」的提示 |
| B5 | `bridge-agy.mjs`、`index.mjs`（`AntigravityBridgePlugin`、`noAgy`、请求入口的 503） | 不再启动 `keepAgyCurrent`（每 6 小时自动更新 agy）；`auth.cli.install` 在 agy 不存在时抛出明确错误，指向 Codex Bridge「连接 → Antigravity」或自行安装 agy 1.4.12 及以上（图片输入需 1.5.0）；`auth.cli.installed` 与 `AGY_PATH` 优先于 `PATH` 的查找顺序不变；`auth.cli.manual` 与「找不到 agy」的提示改为同一说明 |
| B6 | `bridge-agy.mjs`、`index.mjs`（`loader` 的 `baseURL`、`provider.models` 的 `api.url`） | 模型地址占位由 `agy://local` 改为 `http://agy.invalid`：Codex Bridge 的宿主与模型网关只接受 http(s) 地址，原值使所有模型被判为不可用。请求仍全部由插件自己的 fetch 处理，该地址不会被访问 |
