---
name: agent-reach-youtube
description: "Agent Reach 的 youtube 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: youtube_channel
    script: scripts/youtube_channel.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube channel info and recent videos"
  - name: youtube_comments
    script: scripts/youtube_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube video comments"
  - name: youtube_feed
    script: scripts/youtube_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube homepage recommended videos"
  - name: youtube_history
    script: scripts/youtube_history.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube watch history"
  - name: youtube_playlist
    script: scripts/youtube_playlist.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube playlist info and video list"
  - name: youtube_search
    script: scripts/youtube_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search YouTube videos"
  - name: youtube_subscriptions
    script: scripts/youtube_subscriptions.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List subscribed YouTube channels"
  - name: youtube_transcript
    script: scripts/youtube_transcript.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube video transcript/subtitles"
  - name: youtube_video
    script: scripts/youtube_video.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get YouTube video metadata (title, views, description, etc.)"
  - name: youtube_watch_later
    script: scripts/youtube_watch_later.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get your YouTube Watch Later queue"
  - name: youtube_whoami
    script: scripts/youtube_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in youtube account"
---

# Agent Reach · youtube

基于当前 OpenCLI 1.8.7，提供 11 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-youtube"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `youtube_channel` | `opencli youtube channel` | Get YouTube channel info and recent videos |
| `youtube_comments` | `opencli youtube comments` | Get YouTube video comments |
| `youtube_feed` | `opencli youtube feed` | Get YouTube homepage recommended videos |
| `youtube_history` | `opencli youtube history` | Get YouTube watch history |
| `youtube_playlist` | `opencli youtube playlist` | Get YouTube playlist info and video list |
| `youtube_search` | `opencli youtube search` | Search YouTube videos |
| `youtube_subscriptions` | `opencli youtube subscriptions` | List subscribed YouTube channels |
| `youtube_transcript` | `opencli youtube transcript` | Get YouTube video transcript/subtitles |
| `youtube_video` | `opencli youtube video` | Get YouTube video metadata (title, views, description, etc.) |
| `youtube_watch_later` | `opencli youtube watch-later` | Get your YouTube Watch Later queue |
| `youtube_whoami` | `opencli youtube whoami` | Show the current logged-in youtube account |
