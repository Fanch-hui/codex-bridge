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
   保持与 `Config/Base.xcconfig` 的 `MARKETING_VERSION` 一致；构建器会在打包前校验四处版本。
2. 执行 `node Scripts/build-mcpb.mjs`。脚本在临时目录安装精确锁定的依赖，使用
   MCPB 官方打包工具生成 `.build/mcp-registry/codex-bridge-<version>.mcpb`
   和对应的 `server.json`。
3. 将生成的 MCPB 与 `server.json` 一起上传到同版本 GitHub Release，
   与完整 App 安装包一起发布。已发布的 MCPB 版本保持不可变。
4. 在生成的输出目录执行 `mcp-publisher validate`。本地发布使用 `mcp-publisher login github`
   完成人工设备授权，再执行 `mcp-publisher publish`。不要提交 publisher 凭据。
5. `Publish MCP Registry` workflow 在正式 Release 发布后运行，也可通过
   `workflow_dispatch` 指定版本。它检出目标 tag，下载该 Release 的 MCPB 与 `server.json`，
   校验应用版本、包内 manifest、仓库身份与 SHA-256，再使用 GitHub OIDC 发布。

MCPB 的官方验证方式为 GitHub/GitLab Release 下载地址与 `fileSha256`。
仓库所有者由 Registry 的 GitHub 身份认证验证；本项目的下载地址使用同一 owner。
无需额外的 npm 包或 OCI 镜像。

发布后查询：

```sh
curl --fail 'https://registry.modelcontextprotocol.io/v0.1/servers/io.github.Fanch-hui%2Fcodex-bridge/versions/latest'
```

## 官方规范

- [Registry 发布指南](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/quickstart.mdx)
- [包类型与验证](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/package-types.mdx)
- [GitHub OIDC 发布](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/github-actions.mdx)
- [MCPB manifest](https://github.com/anthropics/mcpb/blob/main/MANIFEST.md)
