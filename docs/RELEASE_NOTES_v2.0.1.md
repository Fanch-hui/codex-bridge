# Codex Bridge v2.0.1

## 更新内容

- 修复 DSH 原生桌面任务启动时的执行绑定传递，保留任务的原始请求标识与连接配置。
- 修复 DSH Connector 重连期间重复派发输入的问题，同一请求的并发恢复沿用原启动过程。
- 修复 Linux Secure Tunnel 子进程退出时的输出管道回收崩溃，统一处理输出读取、结束与关闭。
- 改进 Codex 模型目录解析与校验失败的错误诊断，提供错误类别和字段位置。

## 使用提醒

- DSH 原生桌面接入支持 macOS 与 Windows x64；更新 Connector 前，请完全退出 DSH 桌面版。
- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
