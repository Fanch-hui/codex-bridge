# Codex Bridge v2.1.1

## 更新内容

- 新增 Secure Tunnel 启动诊断，可关联每次启动中的轮询、等待就绪和进程退出时间，便于排查偶发连接超时。
- 诊断日志仅保留必要状态和数值；常规日志同步遮蔽 Tunnel ID，方便安全地提交问题反馈。

## 使用提示

- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
- 启动诊断默认关闭。需要排查连接问题时，按[诊断指南](https://github.com/Fanch-hui/codex-bridge/blob/win/docs/TUNNEL_CLIENT_INTEGRATION.md#startup-diagnostics)在启动后台服务前启用。
