# Pi 与 Qoder 连接

Pi 和 Qoder 使用本机安装与各自的原生登录态。先安装 Node.js 22.19 或更新版本，再安装需要的 Agent。macOS Apple Silicon 与 Windows x64 使用同一套连接设置。

## Pi

```sh
npm install -g @earendil-works/pi-coding-agent@0.87.1
pi
```

在 Pi 中运行 `/login` 完成所选模型服务商的登录。返回 Bridge 的“连接”页，点击“扫描 Agent”，再连接 Pi。模型目录来自 Pi 的真实可用模型；目录为空时，需要先在 Pi 完成服务商配置或登录。

## Qoder CN

CLI 与 SDK 必须来自同一地区，并使用配套版本。以下是一组已核对官方契约的版本：

```sh
npm install -g @qodercn-ai/qoderclicn@1.1.64 @qodercn-ai/qodercn-agent-sdk@1.0.50
qoderclicn login
```

在 Bridge 的 Qoder 连接卡选择“中国版”，扫描本机安装，选择活动安装并连接。国际版使用独立的 `@qoder-ai/qodercli` 与 `@qoder-ai/qoder-agent-sdk` 包，在同一张卡中显式选择“国际版”。两版分别保存默认模型与运行配置。

更改地区只影响后续新任务的默认选择。继续已有会话时使用该会话原先绑定的地区与安装。

## 安装发现与运行路径

Bridge 首次初始化时扫描并保存安装目录；升级新增 Agent 时补齐缺失的索引项。之后安装或移动 Agent，请点击“扫描 Agent”。扫描包含 PATH、用户安装目录和常见 Node 包管理器目录。

Qoder 的“Node 路径”和“SDK 目录”可留空，让 Bridge 根据已选 CLI 定位；自定义安装时填写绝对路径。SDK 目录是包含该地区 SDK `package.json` 的目录。Windows npm 包装命令会解析到官方包内的 JavaScript 入口，再使用 Node 执行。

Bridge 会校验 CLI、Node、SDK 与随 App 分发的宿主资源。文件更新后重新探测；若提示版本、地区或摘要不匹配，请修正所选安装及 SDK 后重新连接。

## 常见提示

- **未发现安装**：确认原生命令能显示版本，然后扫描；特殊安装位置可手动指定可执行文件。
- **当前地区尚未登录或登录已失效**：使用所选地区的 CLI 登录后重新连接。
- **SDK 不可用或版本不匹配**：检查 SDK 所属地区及其要求的 CLI 版本，并核对 SDK 目录。
- **模型不可用**：先在原生 Agent 检查模型目录和服务商配置。

MCP 服务按 Pi、Qoder CN、Qoder 国际版分别配置。工具是否可调用还取决于任务网络权限、读写模式与本机审批结果。

工作台续写或重开 Pi/Qoder 任务时，可在 Skills 输入框填写项目 Skills 列表中的名称，多个名称用逗号分隔；留空沿用会话选择。通过 MCP 提交任务时使用 `skill_names`，单个 Skill 也兼容 `skill_name`。
