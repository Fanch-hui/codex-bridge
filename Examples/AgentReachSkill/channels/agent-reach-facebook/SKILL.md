---
name: agent-reach-facebook
description: "Agent Reach 的 facebook 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: facebook_events
    script: scripts/facebook_events.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Browse Facebook event categories"
  - name: facebook_feed
    script: scripts/facebook_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get your Facebook news feed"
  - name: facebook_friends
    script: scripts/facebook_friends.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Facebook friend suggestions"
  - name: facebook_groups
    script: scripts/facebook_groups.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List your Facebook groups"
  - name: facebook_marketplace_inbox
    script: scripts/facebook_marketplace_inbox.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List recent Facebook Marketplace buyer/seller conversations"
  - name: facebook_marketplace_listings
    script: scripts/facebook_marketplace_listings.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List your Facebook Marketplace seller listings"
  - name: facebook_memories
    script: scripts/facebook_memories.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get your Facebook memories (On This Day)"
  - name: facebook_notifications
    script: scripts/facebook_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get recent Facebook notifications (含 unread / time / url / notif_id / notif_type 列)"
  - name: facebook_profile
    script: scripts/facebook_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Facebook user/page profile info"
  - name: facebook_search
    script: scripts/facebook_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Facebook for people, pages, or posts"
  - name: facebook_whoami
    script: scripts/facebook_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in facebook account"
---

# Agent Reach · facebook

基于当前 OpenCLI 1.8.7，提供 11 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-facebook"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `facebook_events` | `opencli facebook events` | Browse Facebook event categories |
| `facebook_feed` | `opencli facebook feed` | Get your Facebook news feed |
| `facebook_friends` | `opencli facebook friends` | Get Facebook friend suggestions |
| `facebook_groups` | `opencli facebook groups` | List your Facebook groups |
| `facebook_marketplace_inbox` | `opencli facebook marketplace-inbox` | List recent Facebook Marketplace buyer/seller conversations |
| `facebook_marketplace_listings` | `opencli facebook marketplace-listings` | List your Facebook Marketplace seller listings |
| `facebook_memories` | `opencli facebook memories` | Get your Facebook memories (On This Day) |
| `facebook_notifications` | `opencli facebook notifications` | Get recent Facebook notifications (含 unread / time / url / notif_id / notif_type 列) |
| `facebook_profile` | `opencli facebook profile` | Get Facebook user/page profile info |
| `facebook_search` | `opencli facebook search` | Search Facebook for people, pages, or posts |
| `facebook_whoami` | `opencli facebook whoami` | Show the current logged-in facebook account |
