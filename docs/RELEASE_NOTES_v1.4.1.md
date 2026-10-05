# Codex Bridge v1.4.1

## 权限设置

- 注册项目即授权该目录完整访问，项目页统一管理目录注册。
- 任务权限统一为“只读”和“完整”：只读禁止写入和联网，完整允许读写和联网。工作台的“Agent 权限”由用户选择，作为 ChatGPT / Qwen 提交任务的默认权限；相关 MCP 接口使用这一设置。
- Codex 完全访问使用免审批执行策略，避免任务配置中的旧联网字段导致执行权限降级。只读任务保留执行沙箱；不能提供只读执行能力的 Agent 会明确提示。
- 旧项目与任务数据继续兼容，原有目录边界、任务审批与会话绑定继续生效。

## 服务与工作台

- 改进 Windows 后台服务启动：识别启动后立即退出的进程，保存启动错误，并为连续失败提供退避与熔断。
- 修复 Windows / Linux 服务恢复后的连接阻塞，以及并发连接请求重复计算启动失败的问题。
- 改进 Windows 桌面增量消息传递，按顺序处理更新并减少 UI 线程上的编码工作。
- 工作台实时对话保留最近 400 条消息，较早内容可通过历史分页加载；保存后的消息标识同步到桌面，避免裁剪与历史衔接异常。
- 概览、连接、日志与更新状态使用更精确的增量推送，减少无关页面刷新。

## Windows 更新与运行

- 限制后台服务的 DLL 搜索范围为应用目录和系统目录。
- 改进便携版更新的暂存与文件替换；更新失败时先恢复已替换文件，再清理临时文件，避免文件占用阻断回滚。

## 下载与安装

| 平台 | 安装包 | 便携包或更新包 |
| --- | --- | --- |
| macOS 14+ Apple Silicon | `CodexBridge-1.4.1-macos-arm64.dmg` | `CodexBridge-1.4.1-macos-arm64.zip` |
| macOS 14+ Intel | `CodexBridge-1.4.1-macos-x86_64.dmg` | `CodexBridge-1.4.1-macos-x86_64.zip` |
| Windows x64 | `CodexBridge-Windows-x64-1.4.1-Setup.exe` | `codex-bridge-windows-x64.zip` |
| Windows ARM64 | `CodexBridge-Windows-arm64-1.4.1-Setup.exe` | `codex-bridge-windows-arm64.zip` |
| Ubuntu 24.04 LTS x64 | `CodexBridge-Linux-x64-1.4.1.deb` | `codex-bridge-linux-x64-1.4.1.tar.gz` |
| Ubuntu 24.04 LTS ARM64 | `CodexBridge-Linux-arm64-1.4.1.deb` | `codex-bridge-linux-arm64-1.4.1.tar.gz` |

macOS 打开 DMG 后将 App 拖入 Applications；安装包使用 ad-hoc 签名，首次打开时按系统提示在“隐私与安全性”中允许。Windows 运行对应架构的安装器，便携包完整解压后运行 `codex-bridge-windows-app.exe`。

Ubuntu 使用 APT 安装 `.deb`，例如：

```bash
sudo apt install ./CodexBridge-Linux-x64-1.4.1.deb
```

Linux 便携包解压后运行 `./codex-bridge`，运行依赖与数据目录见 [Linux 指南](https://github.com/Fanch-hui/codex-bridge/blob/v1.4.1/docs/LINUX.md)。旧服务不支持空闲停服时，先结束任务并退出旧服务，再重试安装；Linux 1.3.5 首次升级需手动下载安装包。

## 使用提示

- 升级沿用已有项目、任务、应用数据与内置浏览器登录态。
- **更新后请在 ChatGPT 的插件设置中刷新 Codex Bridge**，让新的工具接口与权限设置生效。
- 在工作台选择“只读”或“完整”权限；无人值守任务还需按用途配置任务启动与 Direct 操作审批策略。
- Agent 一键配置、已有安装连接与登录方式见 [Agent 一键配置指南](https://github.com/Fanch-hui/codex-bridge/blob/v1.4.1/docs/AGENT_SETUP_GUIDE.md)。
