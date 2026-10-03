# Codex Bridge v1.3.6

## 主要更新

- 修复 Codex 在线模型目录刷新失败后返回旧目录的问题：检测刷新错误后重新启动目录查询进程并重试一次；持续失败时显示明确错误。
- 改进动态模型兼容：目录暂时缺少新模型或推理强度时，保留已保存或明确指定的选择，由 Codex 实际执行确认可用性。设置读取、任务提交与排队均采用这一规则。
- 模型目录刷新失败时保留已有目录和默认模型偏好；手动刷新后以新请求结果为准，避免较早请求覆盖更新后的目录。
- 修复更新清单兼容性：macOS 与 Windows 保持旧版可读取的清单格式，Linux 使用扩展条目，应用按平台、架构和安装方式选择对应安装包。
- 以上服务修复覆盖 macOS、Windows 与 Linux；macOS 同时改进设置页模型刷新结果的回写顺序。

## 下载与安装

| 平台 | 安装包 | 便携包或更新包 |
| --- | --- | --- |
| macOS 14+ Apple Silicon | `CodexBridge-1.3.6-macos-arm64.dmg` | `CodexBridge-1.3.6-macos-arm64.zip` |
| macOS 14+ Intel | `CodexBridge-1.3.6-macos-x86_64.dmg` | `CodexBridge-1.3.6-macos-x86_64.zip` |
| Windows x64 | `CodexBridge-Windows-x64-1.3.6-Setup.exe` | `codex-bridge-windows-x64.zip` |
| Windows ARM64 | `CodexBridge-Windows-arm64-1.3.6-Setup.exe` | `codex-bridge-windows-arm64.zip` |
| Ubuntu 24.04 LTS x64 | `CodexBridge-Linux-x64-1.3.6.deb` | `codex-bridge-linux-x64-1.3.6.tar.gz` |
| Ubuntu 24.04 LTS ARM64 | `CodexBridge-Linux-arm64-1.3.6.deb` | `codex-bridge-linux-arm64-1.3.6.tar.gz` |

macOS 打开 DMG 后将 App 拖入 Applications；安装包使用 ad-hoc 签名，首次打开时按系统提示在“隐私与安全性”中允许。Windows 运行对应架构的安装器，便携包完整解压后运行 `codex-bridge-windows-app.exe`。

**Linux 1.3.5 升级到 1.3.6，需要从本次 Release 手动下载对应架构的安装包并安装。** 安装 1.3.6 后，应用内更新入口支持扩展清单中的 Linux 安装包。

Ubuntu 使用 APT 安装 `.deb`，以同时安装运行依赖，例如：

```bash
sudo apt install ./CodexBridge-Linux-x64-1.3.6.deb
```

Linux 便携包解压后运行 `./codex-bridge`，运行依赖与数据目录见 [Linux 指南](./LINUX.md)。

## 使用提示

- 升级沿用已有项目、任务、应用数据与内置浏览器登录态。
- **更新后请在 ChatGPT 的插件设置中刷新 Codex Bridge**，让工具与模型列表生效。
- Codex 模型目录由本机 Codex 动态提供；目录刷新出错时可再次点击“获取模型”，已保存的默认选择会保留。
