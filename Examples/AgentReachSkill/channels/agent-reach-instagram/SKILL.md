---
name: agent-reach-instagram
description: "Agent Reach 的 instagram 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: instagram_download
    script: scripts/instagram_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download images and videos from Instagram posts and reels"
  - name: instagram_explore
    script: scripts/instagram_explore.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Instagram explore/discover trending posts"
  - name: instagram_followers
    script: scripts/instagram_followers.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List followers of an Instagram user"
  - name: instagram_following
    script: scripts/instagram_following.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List accounts an Instagram user is following"
  - name: instagram_profile
    script: scripts/instagram_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Instagram user profile info"
  - name: instagram_saved
    script: scripts/instagram_saved.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get your saved Instagram posts (optionally from a specific collection)"
  - name: instagram_search
    script: scripts/instagram_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Instagram users"
  - name: instagram_user
    script: scripts/instagram_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get recent posts from an Instagram user"
  - name: instagram_whoami
    script: scripts/instagram_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in instagram account"
---

# Agent Reach · instagram

基于当前 OpenCLI 1.8.7，提供 9 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-instagram"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `instagram_download` | `opencli instagram download` | Download images and videos from Instagram posts and reels |
| `instagram_explore` | `opencli instagram explore` | Instagram explore/discover trending posts |
| `instagram_followers` | `opencli instagram followers` | List followers of an Instagram user |
| `instagram_following` | `opencli instagram following` | List accounts an Instagram user is following |
| `instagram_profile` | `opencli instagram profile` | Get Instagram user profile info |
| `instagram_saved` | `opencli instagram saved` | Get your saved Instagram posts (optionally from a specific collection) |
| `instagram_search` | `opencli instagram search` | Search Instagram users |
| `instagram_user` | `opencli instagram user` | Get recent posts from an Instagram user |
| `instagram_whoami` | `opencli instagram whoami` | Show the current logged-in instagram account |
