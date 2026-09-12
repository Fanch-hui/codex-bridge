---
name: agent-reach-reddit
description: "Agent Reach 的 reddit 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: reddit_frontpage
    script: scripts/reddit_frontpage.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Reddit Frontpage / r/all"
  - name: reddit_home
    script: scripts/reddit_home.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Reddit personalized home feed (Best, requires login)"
  - name: reddit_hot
    script: scripts/reddit_hot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Reddit 热门帖子"
  - name: reddit_popular
    script: scripts/reddit_popular.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Reddit Popular posts (/r/popular)"
  - name: reddit_read
    script: scripts/reddit_read.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a Reddit post and its comments"
  - name: reddit_saved
    script: scripts/reddit_saved.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Browse your saved Reddit posts"
  - name: reddit_search
    script: scripts/reddit_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Reddit Posts"
  - name: reddit_subreddit
    script: scripts/reddit_subreddit.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get posts from a specific Subreddit"
  - name: reddit_subreddit_info
    script: scripts/reddit_subreddit_info.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show metadata for a Reddit subreddit (subscribers, description, created date, NSFW)"
  - name: reddit_subscribed
    script: scripts/reddit_subscribed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List subreddits you are subscribed to"
  - name: reddit_upvoted
    script: scripts/reddit_upvoted.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Browse your upvoted Reddit posts"
  - name: reddit_user
    script: scripts/reddit_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "View a Reddit user profile"
  - name: reddit_user_comments
    script: scripts/reddit_user_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "View a Reddit user's comment history"
  - name: reddit_user_posts
    script: scripts/reddit_user_posts.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "View a Reddit user's submitted posts"
  - name: reddit_whoami
    script: scripts/reddit_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the currently logged-in Reddit user"
---

# Agent Reach · reddit

基于当前 OpenCLI 1.8.7，提供 15 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-reddit"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `reddit_frontpage` | `opencli reddit frontpage` | Reddit Frontpage / r/all |
| `reddit_home` | `opencli reddit home` | Reddit personalized home feed (Best, requires login) |
| `reddit_hot` | `opencli reddit hot` | Reddit 热门帖子 |
| `reddit_popular` | `opencli reddit popular` | Reddit Popular posts (/r/popular) |
| `reddit_read` | `opencli reddit read` | Read a Reddit post and its comments |
| `reddit_saved` | `opencli reddit saved` | Browse your saved Reddit posts |
| `reddit_search` | `opencli reddit search` | Search Reddit Posts |
| `reddit_subreddit` | `opencli reddit subreddit` | Get posts from a specific Subreddit |
| `reddit_subreddit_info` | `opencli reddit subreddit-info` | Show metadata for a Reddit subreddit (subscribers, description, created date, NSFW) |
| `reddit_subscribed` | `opencli reddit subscribed` | List subreddits you are subscribed to |
| `reddit_upvoted` | `opencli reddit upvoted` | Browse your upvoted Reddit posts |
| `reddit_user` | `opencli reddit user` | View a Reddit user profile |
| `reddit_user_comments` | `opencli reddit user-comments` | View a Reddit user's comment history |
| `reddit_user_posts` | `opencli reddit user-posts` | View a Reddit user's submitted posts |
| `reddit_whoami` | `opencli reddit whoami` | Show the currently logged-in Reddit user |
