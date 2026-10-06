# Codex Bridge v1.4.2

## 更新内容

- DSH 新增“原生桌面”连接，复用官方 Desktop 的账号、工具与会话，支持创建、续写、审批、取消、历史浏览及打开对应会话。已有连接继续使用 ACP。
- Antigravity 统一模型与推理强度选择，按官方模型 ID 执行。
- Pi 兼容 Azure 服务商名称变更，补齐 Azure 环境变量；旧模型偏好按当前目录匹配，旧默认不阻断模型列表刷新。
- 修复 Windows Agent 探测及原生桌面连接的兼容问题。

## 使用提示

- DSH 原生桌面支持 macOS 和官方 Windows x64 桌面版的完整权限文本任务，执行时 Desktop 须保持运行。Linux 和 Windows ARM64 继续使用 ACP。
- 首次使用需安装 Connector 并配对；安装或更新前须完全退出 DSH Desktop。详见[原生桌面指南](https://github.com/Fanch-hui/codex-bridge/blob/v1.4.2/docs/DSH_NATIVE_DESKTOP_GUIDE.md)。
- **原生模式的模型与推理强度选择会同步到 DSH 桌面默认，影响后续新建会话。** ACP 与原生模式的偏好分别保存。
- Pi Azure 模型未出现在目录中时，请按提示迁移 Pi 原生配置。
- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
