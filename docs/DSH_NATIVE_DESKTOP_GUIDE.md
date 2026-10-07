# DSH 原生桌面连接

Bridge 的 DSH ACP 与 DSH 桌面是两个独立连接，可以同时使用。ACP 使用 API 配置，DSH 桌面使用官方桌面账号。原生桌面通过 Connector 调用正在运行的官方 Desktop Host，任务使用桌面原生会话、模型配置和账号；Bridge 与 DSH 读取、续写同一 Session ID。

原生模式适用于 macOS 和官方 Windows x64 桌面安装。Linux 与 Windows ARM64 继续使用 ACP。npm 一键配置准备 DSH ACP。升级保留原有 ACP 配置、桌面配对和任务绑定。

## 安装与配对

1. 从 [DSH 官方发布入口](https://github.com/deepseek-ai/deepseek-harness/releases)取得官方桌面安装，启动一次完成初始化和账号配置。
2. 在 Bridge 的“连接 → DSH 桌面”点击“连接”发现本机桌面安装。
3. 完全退出 DSH Desktop，点击“安装 Connector”。Bridge 使用桌面附带 CLI 将经过摘要校验的插件安装到 `desktop` profile。
4. 启动 DSH Desktop，在 Bridge 点击“连接”。核对两边相同的配对确认码，在 DSH 的 Codex Bridge 插件面板中允许连接。
5. 回到 Bridge 点击“检测桌面连接”。配对验证成功后，选择注册项目、模型和“完整”权限执行任务。

原生模式使用 Desktop 已有配置。ACP 的 API Key 与此连接分别管理。

插件升级同样需要先完全退出 Desktop，更新后重启并检测连接。使用 ACP、断开桌面连接或撤销配对保留桌面会话；撤销配对可以在任一端执行。更换原生 profile 或身份后需要重新配对；安装、配对与撤销要求对应 Connector 没有未结束的原生桌面任务。ACP 任务独立运行。

## 模型与任务

**此选择会同步到 DSH 桌面默认，影响后续新建会话。** 模型和推理强度保存等待原生默认持久化并回读确认，界面按保存结果更新。自动推理强度由原生模型配置解析。

ACP 与原生桌面的偏好分别保存。原生模型目录来自已配对 Host，并保留完整 provider/model 标识；桌面修改默认后，重新连接、刷新或提交新任务时重新读取。

新任务要求 Desktop Host 正在运行。任务保存安装、连接方式、profile、项目和输入 requestId；之后选择其他 Agent 不会改变已提交任务、重试或续写的绑定。通过 MCP 使用桌面连接时，provider_id 为 deepseek-harness-desktop；ACP 的 provider_id 保持 deepseek-harness。续写默认保留原会话模型，明确修改时同步会话选择和桌面默认。

首版接受文本任务和完整权限。图片附件、Bridge 临时 Skill、逐任务 MCP 注入、只读执行和隔离工作树会返回不支持；桌面原有工具和扩展使用原生配置。

Bridge 接收所属运行的正文、推理、工具、用量、审批、补充问题和执行状态。停止操作只取消对应输入；桌面自行启动的后续运行独立呈现。连接丢失后以原 requestId 查询回执和持久事件，Connector 为同一身份重连保留 30 秒，超时取消所属运行。确认终态或 Host 退出前，Bridge 保持任务和项目写入占用。

## 历史与打开会话

在注册项目中可以分页浏览原生会话、导入并续写已有会话，以及重命名空闲会话。DSH 当前公开接口没有删除会话能力，界面不提供该操作。

任务或原生历史中的“打开对应会话”会核对绑定。Desktop 离线时由本机宿主启动已验证的官方 App，等待配对实例和 Client 插件，再导航到目标 Session ID 并聚焦窗口。

## 常见处理

| 状态 | 处理 |
|---|---|
| Connector 尚未就绪 | 启动 DSH 桌面后连接；仍失败时完全退出桌面并重新安装 Connector |
| 系统凭据存储拒绝访问 | 完成系统授权后重新检测；保留原 API 配置 |
| 安装要求退出 Desktop | 从桌面菜单或托盘完全退出后重试 |
| 安装提示需要初始化 | 先启动一次官方桌面，再退出并安装 |
| 配对等待确认 | 在 DSH 插件面板核对确认码并允许连接，再检测 |
| profile 或身份变化 | 等所属 Bridge 任务结束后重新配对 |
| 模型保存失败 | 查看错误并检测连接；按回读结果核对桌面默认与会话模型 |
| 原生会话忙碌 | 等待桌面或 Bridge 的当前运行结束后续写 |
| 打开会话未确认 | 确认桌面窗口及 Client 插件已加载，再点击打开 |

## 验证

公开源码可校验随包 Connector 等 Agent 资源与内置摘要是否一致：

```sh
node Scripts/verify-agent-runtime-resources.mjs
```

以下 Swift 测试、Node 测试与 fixture 仅适用于包含 `Packages/BridgeCore/Tests` 的完整开发树；公开仓库不包含这些测试文件。针对性 Swift 测试使用项目规定的构建系统：

```sh
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --build-system swiftbuild \
  --filter 'BridgeDeepSeekHarnessDesktopTests|DeepSeekDesktop|DeepSeekRuntimeBinding'
```

Connector 的真实 Host 测试使用独立 npm prefix、profile、项目和测试模型提供方。它不要求用户账号或凭据：

```sh
npm install --prefix /tmp/bridge-dsh-connector-live-test \
  --cache /tmp/bridge-dsh-connector-live-test/npm-cache \
  --ignore-scripts --no-audit --no-fund @deepseek-ai/dsh@0.2.0-rc.2
CODEX_BRIDGE_DSH_TEST_RUNTIME=/tmp/bridge-dsh-connector-live-test \
  node --test Packages/BridgeCore/Tests/BridgeDeepSeekHarnessDesktopTests/DeepSeekHarnessDesktopConnectorTests.mjs
```

测试 fixture 使用官方 Loader 和原生服务，检查会话执行、续写、默认保存、审批、问题、取消归属、去重和分页。测试结束清理 fixture 数据；上述 npm prefix 与下载缓存由运行者清理。

桌面 UI 与已登录账号由用户手动验收：安装及升级 Connector、确认配对、执行短任务、核对两端 Session ID 和消息、续写、模型默认重启保留、审批与取消、桌面独立任务、打开目标窗口、撤销配对及两个连接同时使用。协议和测试模型通过分别记录，窗口显示与账号执行以直接验收结果为准。

官方扩展接口见 [Desktop 文档](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/apps/desktop/README.zh.md) 与 [SessionController](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/packages/api/session-controller/src/index.ts)。
