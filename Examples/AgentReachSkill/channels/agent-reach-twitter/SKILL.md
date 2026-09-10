---
name: agent-reach-twitter
description: "Agent Reach 的 twitter 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: twitter_article
    script: scripts/twitter_article.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch a Twitter Article (long-form content) and export as Markdown"
  - name: twitter_bookmark_folder
    script: scripts/twitter_bookmark_folder.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read the tweets inside a single Twitter/X bookmark folder. Get the folder id from `opencli twitter bookmark-folders`."
  - name: twitter_bookmark_folders
    script: scripts/twitter_bookmark_folders.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List your Twitter/X bookmark folders (the user-created collections under Bookmarks). Returns folder id, name, item count, and created_at."
  - name: twitter_bookmarks
    script: scripts/twitter_bookmarks.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch your Twitter/X bookmarks (the logged-in user's saved tweets, newest first)"
  - name: twitter_collection
    script: scripts/twitter_collection.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch a user timeline with relationship facts and a bounded completion receipt."
  - name: twitter_device_follow
    script: scripts/twitter_device_follow.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read the /i/timeline device-follow notification stream (tweets aggregated under a bell-icon \"new posts from @userA and N others\" notification)"
  - name: twitter_download
    script: scripts/twitter_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download Twitter/X media (images and videos). Provide either <username> to fetch every media item from their profile via the GraphQL UserMedia endpoint with cursor pagination, or --tweet-url to download a single tweet."
  - name: twitter_followers
    script: scripts/twitter_followers.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get accounts following a Twitter/X user (defaults to the logged-in user when no user is given)"
  - name: twitter_following
    script: scripts/twitter_following.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get accounts a Twitter/X user is following (defaults to the logged-in user when no user is given)"
  - name: twitter_likes
    script: scripts/twitter_likes.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch liked tweets of a Twitter user (defaults to the logged-in user when no username is given)"
  - name: twitter_list_tweets
    script: scripts/twitter_list_tweets.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch tweets from a Twitter/X list timeline"
  - name: twitter_lists
    script: scripts/twitter_lists.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get Twitter/X lists for the logged-in user (owned + subscribed)"
  - name: twitter_notifications
    script: scripts/twitter_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get your Twitter/X notifications (the logged-in user's likes/replies/follows feed, newest first)"
  - name: twitter_profile
    script: scripts/twitter_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch a Twitter user profile — bio, stats, etc. (defaults to the logged-in user when no username is given)"
  - name: twitter_search
    script: scripts/twitter_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Twitter/X for tweets, with optional --from / --has / --exclude / --product filters mapped to X's search operators"
  - name: twitter_thread
    script: scripts/twitter_thread.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get a tweet thread (original + all replies)"
  - name: twitter_timeline
    script: scripts/twitter_timeline.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch the logged-in user's home timeline (for-you algorithmic feed by default; pass --type following for the chronological feed of accounts you follow)"
  - name: twitter_trending
    script: scripts/twitter_trending.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Twitter/X trending topics"
  - name: twitter_tweets
    script: scripts/twitter_tweets.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Fetch a Twitter user's most recent tweets (chronological, excludes pinned; defaults to the logged-in user when no username is given)"
  - name: twitter_whoami
    script: scripts/twitter_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in twitter account"
---

# Agent Reach · twitter

基于当前 OpenCLI 1.8.7，提供 20 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-twitter"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `twitter_article` | `opencli twitter article` | Fetch a Twitter Article (long-form content) and export as Markdown |
| `twitter_bookmark_folder` | `opencli twitter bookmark-folder` | Read the tweets inside a single Twitter/X bookmark folder. Get the folder id from `opencli twitter bookmark-folders`. |
| `twitter_bookmark_folders` | `opencli twitter bookmark-folders` | List your Twitter/X bookmark folders (the user-created collections under Bookmarks). Returns folder id, name, item count, and created_at. |
| `twitter_bookmarks` | `opencli twitter bookmarks` | Fetch your Twitter/X bookmarks (the logged-in user's saved tweets, newest first) |
| `twitter_collection` | `opencli twitter collection` | Fetch a user timeline with relationship facts and a bounded completion receipt. |
| `twitter_device_follow` | `opencli twitter device-follow` | Read the /i/timeline device-follow notification stream (tweets aggregated under a bell-icon "new posts from @userA and N others" notification) |
| `twitter_download` | `opencli twitter download` | Download Twitter/X media (images and videos). Provide either <username> to fetch every media item from their profile via the GraphQL UserMedia endpoint with cursor pagination, or --tweet-url to download a single tweet. |
| `twitter_followers` | `opencli twitter followers` | Get accounts following a Twitter/X user (defaults to the logged-in user when no user is given) |
| `twitter_following` | `opencli twitter following` | Get accounts a Twitter/X user is following (defaults to the logged-in user when no user is given) |
| `twitter_likes` | `opencli twitter likes` | Fetch liked tweets of a Twitter user (defaults to the logged-in user when no username is given) |
| `twitter_list_tweets` | `opencli twitter list-tweets` | Fetch tweets from a Twitter/X list timeline |
| `twitter_lists` | `opencli twitter lists` | Get Twitter/X lists for the logged-in user (owned + subscribed) |
| `twitter_notifications` | `opencli twitter notifications` | Get your Twitter/X notifications (the logged-in user's likes/replies/follows feed, newest first) |
| `twitter_profile` | `opencli twitter profile` | Fetch a Twitter user profile — bio, stats, etc. (defaults to the logged-in user when no username is given) |
| `twitter_search` | `opencli twitter search` | Search Twitter/X for tweets, with optional --from / --has / --exclude / --product filters mapped to X's search operators |
| `twitter_thread` | `opencli twitter thread` | Get a tweet thread (original + all replies) |
| `twitter_timeline` | `opencli twitter timeline` | Fetch the logged-in user's home timeline (for-you algorithmic feed by default; pass --type following for the chronological feed of accounts you follow) |
| `twitter_trending` | `opencli twitter trending` | Twitter/X trending topics |
| `twitter_tweets` | `opencli twitter tweets` | Fetch a Twitter user's most recent tweets (chronological, excludes pinned; defaults to the logged-in user when no username is given) |
| `twitter_whoami` | `opencli twitter whoami` | Show the current logged-in twitter account |
