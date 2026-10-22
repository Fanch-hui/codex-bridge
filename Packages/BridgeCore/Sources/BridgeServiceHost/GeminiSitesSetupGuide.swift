enum GeminiSitesSetupGuide {
  static let prompt =
    """
    请帮我部署 Codex Bridge 的 Gemini Cloud MCP 转发站点。

    请从公开仓库 https://github.com/Fanch-hui/codex-bridge 的 win 分支取得 Integrations/GeminiSites 完整模板，并先阅读该目录的 README。按模板创建一个新的 ChatGPT Sites 站点并公开部署，保留真实的 MCP 请求转发、D1 队列，以及本机 Bridge 主动领取请求和回传结果的接口。使用模板自己的构建脚本，不要用只有演示工具或静态页面的站点代替。

    我会另行通过受保护的 Secret 配置方式提供 Bridge「复制 Sites 托管配置」中的两项值。请将 BRIDGE_MCP_KEY 和 BRIDGE_RELAY_KEY 分别设置为站点运行时 Secret；缺少配置时提示我完成 Secret 设置。不要将它们写入源码、hosting.json、公开网页、日志或回复，也不要在回复中输出含密钥的 Gemini 连接链接。

    部署完成后，请返回站点的 HTTPS 根地址和部署结果，方便我填回 Bridge。随后告诉我：在 Bridge 保存该根地址并启用云 MCP，等待连接成功，再从 Bridge 复制完整连接链接，到 Gemini 网页版的「设置 → Connected Apps → Add a custom app」添加自定义应用（若找不到 Connected Apps，先进入 Personal Intelligence），粘贴完整连接链接并将 OAuth 高级选项留空；点击下一步，核对工具列表、将应用名称填写为 Codex Bridge，然后完成关联。完成关联后，在 Gemini 聊天或任务中输入 @ 并选择 Codex Bridge，再调用 bridge_status 和 list_projects 检查连接。
    """
}
