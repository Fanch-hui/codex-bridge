---
name: agent-reach-rednote
description: "Agent Reach 的 rednote 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: rednote_comments
    script: scripts/rednote_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read comments from a rednote note (supports nested replies)"
  - name: rednote_download
    script: scripts/rednote_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download images and videos from a rednote note"
  - name: rednote_feed
    script: scripts/rednote_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Rednote home feed (reads hydrated Pinia store)"
  - name: rednote_note
    script: scripts/rednote_note.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read note body and engagement counts from a rednote note"
  - name: rednote_notifications
    script: scripts/rednote_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Rednote notifications (mentions/likes/connections)"
  - name: rednote_search
    script: scripts/rednote_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search rednote notes"
  - name: rednote_user
    script: scripts/rednote_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get public notes from a rednote user profile"
  - name: rednote_whoami
    script: scripts/rednote_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in rednote account"
---

# Agent Reach · rednote

基于当前 OpenCLI 1.8.7，提供 8 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-rednote"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

国际版小红书 / Rednote / rednote.com 对应 `www.rednote.com`；使用 `opencli rednote`，不可回退国内版。读取 `doctor --json` 的独立 `rednote` channel。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `rednote_comments` | `opencli rednote comments` | Read comments from a rednote note (supports nested replies) |
| `rednote_download` | `opencli rednote download` | Download images and videos from a rednote note |
| `rednote_feed` | `opencli rednote feed` | Rednote home feed (reads hydrated Pinia store) |
| `rednote_note` | `opencli rednote note` | Read note body and engagement counts from a rednote note |
| `rednote_notifications` | `opencli rednote notifications` | Rednote notifications (mentions/likes/connections) |
| `rednote_search` | `opencli rednote search` | Search rednote notes |
| `rednote_user` | `opencli rednote user` | Get public notes from a rednote user profile |
| `rednote_whoami` | `opencli rednote whoami` | Show the current logged-in rednote account |
