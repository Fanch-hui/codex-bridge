# Codex Bridge v2.2.3

## 更新内容

- 修复 Windows Secure MCP Tunnel 健康端口校验中的缓冲区变化与内存读取问题，提高连接状态识别的稳定性。
- 改进 Tunnel 启动诊断，分别记录健康地址文件、端口归属、就绪响应和远端轮询结果，并提供系统错误码，方便定位连接问题。
- 同步后台服务报告的版本号，便于核对当前运行版本。

## 使用提示

- 更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。
- 如需排查 Tunnel 启动问题，请按[诊断指南](https://github.com/Fanch-hui/codex-bridge/blob/v2.2.3/docs/TUNNEL_CLIENT_INTEGRATION.md#startup-diagnostics)启用 `CODEX_BRIDGE_TUNNEL_DIAGNOSTICS=1`，收集一轮启动记录。
