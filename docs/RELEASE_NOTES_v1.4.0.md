# Codex Bridge v1.4.0

## 主要更新

- 新增 Agent 一键配置：在“连接 → 本机 Agent 引擎连接”中，为 OpenCode、DeepSeek Harness、Antigravity、Pi 和 Qoder 准备程序、运行依赖、登录或 API 配置，并检测接口与模型目录。已有安装继续自动发现，点击“连接”即可使用；Codex 沿用独立的执行引擎连接。
- 优先复用已有兼容安装；新增程序默认安装到服务数据目录的 `AgentTools`，也可指定当前用户可写的绝对路径。缺少 Node/npm 时准备独立运行时，无需修改全局 PATH。
- 一键配置支持进度查看、取消与重试；离开连接页后安装继续运行。OpenCode、Pi、Qoder 和 Antigravity 提供原生登录或配置入口，DSH 提供服务地址与 API Key 编辑器。Qoder 中国版与国际版分别管理运行时和登录态，验证后切换活动连接。
- 更新 OpenCode 版本兼容判断：满足最低版本要求后，通过原生 ACP 握手确认兼容性，支持后续官方版本。

## 连接与工作台修复

- 修复 DSH Desktop 与 npm 安装被错误拒绝的问题，按实际安装布局校验所需运行工件。
- 修复 DSH 配置使用 Windows CRLF 换行时的模板误判；重新连接时更新服务自动生成的旧版原始模板，保留手动配置和用户编辑过的模板。
- 工作台删除会话改为页内二次确认，刷新对话时保留操作按钮与焦点。
- 修复连续修改 Codex 模型、推理强度、权限与快速模式时的保存竞态，合并待保存设置并按顺序提交，避免新选择被旧请求覆盖。
- 模型目录请求按安装与项目隔离；切换项目或重新刷新后，旧请求不会覆盖当前目录与偏好。
- 统一 Agent 立即提交与排队启动时的模型校验，修复目录并发查询和默认模型处理不一致的问题；任务使用实际项目范围内的技能指令。
- 修复 Pi 与 OpenCode 在任务即将完成时接收新输入的竞态，避免已接受的输入被提前结算。Pi 子任务核对输入回执、完整最终消息与完成事件，正确反馈失败或未完成状态。

## 运行与权限改进

- Direct 命令输出、历史列表与中断结果按当前项目读取权限检查；外部 Agent 启动前复核项目目录身份和权限。文件修改与撤销审批显示实际操作类型和受影响文件。
- 改进 macOS 与 Linux 托管进程的停止行为，父进程退出后仍会结束所属进程组；Direct Git 取消或超时时先结束进程，再释放工作区占用与索引锁。
- Windows Tunnel 使用独立运行环境，限制从宿主继承的环境变量，并使用私有临时目录与 Codex 配置目录。
- 改进 Linux `.deb` 升级：服务空闲时先停止服务并等待退出，再替换安装文件；存在未结束的 Agent 任务、Direct 命令或工作区写操作时提示稍后重试，包替换期间阻止服务重新启动。

## 下载与安装

| 平台 | 安装包 | 便携包或更新包 |
| --- | --- | --- |
| macOS 14+ Apple Silicon | `CodexBridge-1.4.0-macos-arm64.dmg` | `CodexBridge-1.4.0-macos-arm64.zip` |
| macOS 14+ Intel | `CodexBridge-1.4.0-macos-x86_64.dmg` | `CodexBridge-1.4.0-macos-x86_64.zip` |
| Windows x64 | `CodexBridge-Windows-x64-1.4.0-Setup.exe` | `codex-bridge-windows-x64.zip` |
| Windows ARM64 | `CodexBridge-Windows-arm64-1.4.0-Setup.exe` | `codex-bridge-windows-arm64.zip` |
| Ubuntu 24.04 LTS x64 | `CodexBridge-Linux-x64-1.4.0.deb` | `codex-bridge-linux-x64-1.4.0.tar.gz` |
| Ubuntu 24.04 LTS ARM64 | `CodexBridge-Linux-arm64-1.4.0.deb` | `codex-bridge-linux-arm64-1.4.0.tar.gz` |

macOS 打开 DMG 后将 App 拖入 Applications；安装包使用 ad-hoc 签名，首次打开时按系统提示在“隐私与安全性”中允许。Windows 运行对应架构的安装器，便携包完整解压后运行 `codex-bridge-windows-app.exe`。

Ubuntu 使用 APT 安装 `.deb`，以同时安装运行依赖，例如：

```bash
sudo apt install ./CodexBridge-Linux-x64-1.4.0.deb
```

Linux 1.3.5 升级需要从本次 Release 手动下载对应架构的安装包。已有旧服务不支持空闲停服时，先结束任务并退出旧服务，再重试安装。Linux 便携包解压后运行 `./codex-bridge`，运行依赖与数据目录见 [Linux 指南](https://github.com/Fanch-hui/codex-bridge/blob/v1.4.0/docs/LINUX.md)。

## 使用提示

- 升级沿用已有项目、任务、应用数据与内置浏览器登录态。
- **更新后请在 ChatGPT 的插件设置中刷新 Codex Bridge**，让工具与模型列表生效。
- Agent 一键配置入口与安装位置说明见 [Agent 一键配置指南](https://github.com/Fanch-hui/codex-bridge/blob/v1.4.0/docs/AGENT_SETUP_GUIDE.md)。完成安装后，按提示登录或填写 API，再选择模型；实际认证和额度以任务执行结果为准。Qoder 官方目前不提供 Windows ARM64 运行时，该平台会提示使用受支持的平台。
- DSH 的 Bridge 配置使用 API Key；DSH Desktop 的账号 OAuth 登录属于独立账号路由。Antigravity 配置需要明确确认当前用户的全局 Tool Permission 为 Always Proceed；DSH 凭据与 Antigravity 全局权限修改前，需要先结束该 Agent 的任务。
- 开启“退出 App 后继续运行服务”后，即使退出 App，仍可通过 ChatGPT 的 Codex Bridge 插件远程使用本机。请配置好客户端与项目权限；需要无人值守运行时，将相关审批策略设为“自动批准”。
