# Codex Bridge v2.0.4

## 更新内容

- 修复 Antigravity 在使用代理时可能初始化失败或任务启动超时的问题。任务启动与 CLI 命令继承父进程的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 及对应小写环境变量。

## 使用提醒

- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
- 使用代理运行 Antigravity 时，请确保启动 Codex Bridge 的环境中已配置相应代理变量。
