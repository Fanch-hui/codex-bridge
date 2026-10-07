# Codex Bridge v1.4.4

## 更新内容

- macOS、Windows 与 Linux 的连接页新增 Secure Tunnel 控制面代理设置，可单独保存、修改和清除代理；保存后自动重连已启用的 Tunnel。
- 修复 Tunnel 就绪状态判断：本机健康检查通过后，还需近期成功连接 OpenAI 控制面，才显示远端已就绪。
- 改善 macOS 辅助程序签名验证的兼容性。
- 补充 Tunnel 代理配置和连接诊断指南，便于排查本机正常但远端无法连接的情况。

## 使用提醒

- 需要代理时，在“连接”页的 Secure Tunnel 配置中填写无鉴权的 HTTP(S) 代理地址；留空使用直连，修改代理无需重新填写 API Key。
- 代理仅用于 OpenAI 控制面，不自动继承系统或环境代理；SOCKS 代理和包含账号、密码的代理地址不受支持。
- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
