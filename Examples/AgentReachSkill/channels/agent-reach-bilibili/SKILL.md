---
name: agent-reach-bilibili
description: "Agent Reach 的 bilibili 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: bilibili_comments
    script: scripts/bilibili_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取 B站视频评论（官方 API；用 --parent <rpid> 读取某条评论下的「楼中楼」回复）"
  - name: bilibili_download
    script: scripts/bilibili_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "下载B站视频（需要 yt-dlp）"
  - name: bilibili_dynamic
    script: scripts/bilibili_dynamic.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Bilibili user dynamic feed"
  - name: bilibili_feed
    script: scripts/bilibili_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "动态时间线（不传 uid 查关注时间线，传 uid 查指定用户动态）"
  - name: bilibili_feed_detail
    script: scripts/bilibili_feed_detail.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "查看 Bilibili 动态详情（支持充电专属内容）"
  - name: bilibili_following
    script: scripts/bilibili_following.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取 Bilibili 用户的关注列表"
  - name: bilibili_history
    script: scripts/bilibili_history.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "我的观看历史"
  - name: bilibili_hot
    script: scripts/bilibili_hot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "B站热门视频"
  - name: bilibili_me
    script: scripts/bilibili_me.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "My Bilibili profile info"
  - name: bilibili_ranking
    script: scripts/bilibili_ranking.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Bilibili video ranking board"
  - name: bilibili_search
    script: scripts/bilibili_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Bilibili videos or users"
  - name: bilibili_subtitle
    script: scripts/bilibili_subtitle.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取 Bilibili 视频的字幕"
  - name: bilibili_summary
    script: scripts/bilibili_summary.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取 B站视频的官方 AI 总结（视频页「AI总结」同款，含分段大纲与时间戳）"
  - name: bilibili_user_videos
    script: scripts/bilibili_user_videos.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "查看指定用户的投稿视频"
  - name: bilibili_video
    script: scripts/bilibili_video.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Bilibili video metadata (title, author, duration, stats, etc.)"
  - name: bilibili_whoami
    script: scripts/bilibili_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in bilibili account"
---

# Agent Reach · bilibili

基于当前 OpenCLI 1.8.7，提供 16 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-bilibili"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `bilibili_comments` | `opencli bilibili comments` | 获取 B站视频评论（官方 API；用 --parent <rpid> 读取某条评论下的「楼中楼」回复） |
| `bilibili_download` | `opencli bilibili download` | 下载B站视频（需要 yt-dlp） |
| `bilibili_dynamic` | `opencli bilibili dynamic` | Get Bilibili user dynamic feed |
| `bilibili_feed` | `opencli bilibili feed` | 动态时间线（不传 uid 查关注时间线，传 uid 查指定用户动态） |
| `bilibili_feed_detail` | `opencli bilibili feed-detail` | 查看 Bilibili 动态详情（支持充电专属内容） |
| `bilibili_following` | `opencli bilibili following` | 获取 Bilibili 用户的关注列表 |
| `bilibili_history` | `opencli bilibili history` | 我的观看历史 |
| `bilibili_hot` | `opencli bilibili hot` | B站热门视频 |
| `bilibili_me` | `opencli bilibili me` | My Bilibili profile info |
| `bilibili_ranking` | `opencli bilibili ranking` | Get Bilibili video ranking board |
| `bilibili_search` | `opencli bilibili search` | Search Bilibili videos or users |
| `bilibili_subtitle` | `opencli bilibili subtitle` | 获取 Bilibili 视频的字幕 |
| `bilibili_summary` | `opencli bilibili summary` | 获取 B站视频的官方 AI 总结（视频页「AI总结」同款，含分段大纲与时间戳） |
| `bilibili_user_videos` | `opencli bilibili user-videos` | 查看指定用户的投稿视频 |
| `bilibili_video` | `opencli bilibili video` | Get Bilibili video metadata (title, author, duration, stats, etc.) |
| `bilibili_whoami` | `opencli bilibili whoami` | Show the current logged-in bilibili account |
