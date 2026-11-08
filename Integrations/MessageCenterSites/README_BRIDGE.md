# Codex Bridge 消息中心

本站提供开发者公告、私密反馈、截图和回复，部署于 ChatGPT Sites。

管理入口：https://codex-bridge-message-center.canhuifan6.chatgpt.site

管理员使用 ChatGPT 登录。站点的 `MESSAGE_CENTER_ADMIN_EMAIL` Secret 限定管理员身份；普通用户在 App 内通过每条反馈的独立凭据读写自己的对话。所有管理接口与 MCP 工具在服务端重新鉴权。

## 结构

- `worker/message-center`：公告、反馈、截图及管理 API，Sites MCP 管理工具。
- `app/components`：中文通知编辑、预览、发布和反馈管理界面。
- `db/schema.ts`、`drizzle`：D1 数据与版本迁移。
- `.openai/hosting.json`：当前站点身份与 D1、R2、MCP 声明。
- `Tests`：真实 SQLite 与隔离 R2 接口回归。

桌面端使用共享 `MessageCenterController`，将反馈凭据保存于系统 SecretStore；页面快照只承载内容、元数据和操作状态。App 请求使用 `CodexBridge` User-Agent。

## 数据与资源

公告按平台和版本筛选、重要优先分页，每页最多 50 条、响应不超过 900 KiB。反馈正文每条最多 16,000 UTF-8 字节，每个对话最多 80 条，并限制编码后的总量。每条反馈最多 3 张 PNG、JPEG 或 WebP 截图，合计 10 MiB。

附件总预算默认 512 MiB，可通过 `MESSAGE_CENTER_ATTACHMENT_LIMIT_BYTES` 调整。未提交附件在 24 小时后由有界惰性清理回收；删除反馈先持久化对象清理队列，再回收 R2 文件。管理员删除会话后，客户端凭据即无法读取服务端记录。

## 开发与部署

采用 Sites 提供的 Vinext 基础工程，构建与托管流程见 Sites 技能；默认框架说明保留于 `README.md`。使用独立 Sites 源码 checkout 同步本目录，维护已部署站点的原 `project_id`，通过官方 source workflow 提交、构建与打包。

```sh
npm run install:ci
npx tsc --noEmit
node --experimental-strip-types --test Tests/message-center.test.mjs app/components/notice-save.test.ts
npm run build
```

站点运行时 Secret 由 Sites 管理；将管理身份保持在服务端。发布通知和回复直接写数据库，日常管理使用网页或 Sites 自动生成的消息中心插件。
