# MCP Registry 与 MCPB

Registry name：`io.github.Fanch-hui/codex-bridge`。

MCPB 是可选的本机连接器，供支持 MCP Bundles 的客户端安装。使用前先安装并运行
Codex Bridge，在 App 连接页启用 Qwen 本地 HTTP 连接，再将页面提供的本机 URL 与
API key 填入 MCPB 安装表单。连接器需要 Node.js 22 或更新版本；支持内置 Node 的
MCPB 客户端可使用其运行时。API key 由客户端的敏感配置管理，通过环境变量传入连接器。

连接器只接受本机回环地址，通过现有 HTTP MCP 接口转发消息。工具目录、工具结果、
客户端工具权限、项目策略、任务权限与本机审批均由 Bridge 服务决定。此连接与 Qwen
共用客户端身份和权限设置。普通用户继续从 GitHub Releases 安装 macOS 或 Windows App。

## 发布

1. 更新 `Integrations/MCPB/manifest.json`、`package.json` 与锁文件中的版本，
   保持与目标 App Release 一致。
2. 执行 `node Scripts/build-mcpb.mjs`。脚本在临时目录安装精确锁定的依赖，使用
   MCPB 官方打包工具生成 `.build/mcp-registry/codex-bridge-<version>.mcpb`
   和对应的 `server.json`。
3. 将生成的 `server.json` 更新到仓库根目录。把 MCPB 文件上传到同版本的 GitHub
   Release，与完整 App 安装包一起发布；已发布的 MCPB 版本保持不可变。
4. 执行 `mcp-publisher validate`。本地发布使用 `mcp-publisher login github`
   完成人工设备授权，再执行 `mcp-publisher publish`。不要提交 publisher 凭据。
5. `Publish MCP Registry` workflow 在正式 Release 发布后运行，也可通过
   `workflow_dispatch` 指定版本。它下载 Release 中的 MCPB、核对根目录
   `server.json` 的 SHA-256，使用 GitHub OIDC 认证并发布 Registry 元数据。

MCPB 的官方验证方式为 GitHub/GitLab Release 下载地址与 `fileSha256`。
仓库所有者由 Registry 的 GitHub 身份认证验证；本项目的下载地址使用同一 owner。
无需额外的 npm 包或 OCI 镜像。

发布后查询：

```sh
curl --fail 'https://registry.modelcontextprotocol.io/v0.1/servers/io.github.yeyuancc0-glitch%2Fcodex-bridge/versions/latest'
```

## 官方规范

- [Registry 发布指南](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/quickstart.mdx)
- [包类型与验证](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/package-types.mdx)
- [GitHub OIDC 发布](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/github-actions.mdx)
- [MCPB manifest](https://github.com/anthropics/mcpb/blob/main/MANIFEST.md)
