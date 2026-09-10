---
name: agent-reach-github
description: "Agent Reach 的 github 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: github_whoami
    script: scripts/github_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in github account"
---

# Agent Reach · github

基于当前 OpenCLI 1.8.7，提供 1 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-github"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `github_whoami` | `opencli github whoami` | Show the current logged-in github account |
