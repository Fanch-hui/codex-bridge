# Codex Bridge v2.1.0

## 更新内容

- 新增 Gemini 本地 MCP 接入，支持能够启动本机程序的 Gemini 桌面客户端；连接页提供本地启动命令复制入口。
- 新增 Gemini 云 MCP，提供 ChatGPT Sites（公开）与 ngrok 两种方式。Sites 使用完整转发模板，连接页可复制「让 Codex 帮你配置」提示词与托管配置。
- 内置聊天浏览器支持切换 ChatGPT 与 Gemini，分别保留页面、历史与登录数据。
- 统一 macOS、Windows 与 Linux 的界面组件、页面分组和详情布局。
- 调整工作台为紧凑工具栏，支持窄面板换行；会话滚动区上下边缘加入渐进模糊，保留正文可用空间。
- 补齐 Gemini 从「更多 → 自定义 → 关联应用 → 右上角『＋自定义』」到工具确认和关联的完整指南。

## 使用提示

- **更新后请在 ChatGPT 插件设置中刷新 Codex Bridge。**
- Gemini 本地 MCP 使用 Bridge 复制的本地启动命令；云 MCP 将 HTTPS 根地址保存到 Bridge，再把 Bridge 生成的完整专用链接粘贴到 Gemini。Cloud MCP 高级 OAuth 配置留空，点击下一步后核对工具并填写应用名称 `Codex Bridge`。
- 使用期间保持 Bridge 后台服务运行；ngrok 方式还需保持 ngrok 进程运行。重置 Gemini 凭据后需更新连接链接，Sites 还需同步更新两项运行时 Secret。
