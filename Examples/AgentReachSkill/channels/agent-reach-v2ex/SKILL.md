---
name: agent-reach-v2ex
description: "Agent Reach 的 v2ex 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: v2ex_hot
    script: scripts/v2ex_hot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 热门话题"
  - name: v2ex_latest
    script: scripts/v2ex_latest.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 最新话题"
  - name: v2ex_me
    script: scripts/v2ex_me.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 获取个人资料 (余额/未读提醒)"
  - name: v2ex_member
    script: scripts/v2ex_member.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 用户资料"
  - name: v2ex_node
    script: scripts/v2ex_node.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 节点话题列表"
  - name: v2ex_nodes
    script: scripts/v2ex_nodes.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 所有节点列表"
  - name: v2ex_notifications
    script: scripts/v2ex_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 获取提醒 (回复/由于)"
  - name: v2ex_replies
    script: scripts/v2ex_replies.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 主题回复列表"
  - name: v2ex_topic
    script: scripts/v2ex_topic.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 主题详情和回复"
  - name: v2ex_user
    script: scripts/v2ex_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "V2EX 用户发帖列表"
  - name: v2ex_whoami
    script: scripts/v2ex_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in v2ex account"
---

# Agent Reach · v2ex

基于当前 OpenCLI 1.8.7，提供 11 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-v2ex"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `v2ex_hot` | `opencli v2ex hot` | V2EX 热门话题 |
| `v2ex_latest` | `opencli v2ex latest` | V2EX 最新话题 |
| `v2ex_me` | `opencli v2ex me` | V2EX 获取个人资料 (余额/未读提醒) |
| `v2ex_member` | `opencli v2ex member` | V2EX 用户资料 |
| `v2ex_node` | `opencli v2ex node` | V2EX 节点话题列表 |
| `v2ex_nodes` | `opencli v2ex nodes` | V2EX 所有节点列表 |
| `v2ex_notifications` | `opencli v2ex notifications` | V2EX 获取提醒 (回复/由于) |
| `v2ex_replies` | `opencli v2ex replies` | V2EX 主题回复列表 |
| `v2ex_topic` | `opencli v2ex topic` | V2EX 主题详情和回复 |
| `v2ex_user` | `opencli v2ex user` | V2EX 用户发帖列表 |
| `v2ex_whoami` | `opencli v2ex whoami` | Show the current logged-in v2ex account |
