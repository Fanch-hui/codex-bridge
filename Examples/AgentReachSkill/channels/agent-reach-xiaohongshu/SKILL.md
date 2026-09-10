---
name: agent-reach-xiaohongshu
description: "Agent Reach 的 xiaohongshu 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: xiaohongshu_comments
    script: scripts/xiaohongshu_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取小红书笔记评论（支持楼中楼子回复）"
  - name: xiaohongshu_creator_note_detail
    script: scripts/xiaohongshu_creator_note_detail.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书单篇笔记详情页数据 (笔记信息 + 核心/互动数据 + 观看来源 + 观众画像 + 趋势数据)"
  - name: xiaohongshu_creator_notes
    script: scripts/xiaohongshu_creator_notes.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书创作者笔记列表 + 每篇数据 (标题/日期/观看/点赞/收藏/评论)"
  - name: xiaohongshu_creator_notes_summary
    script: scripts/xiaohongshu_creator_notes_summary.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书最近笔记批量摘要 (列表 + 单篇关键数据汇总)"
  - name: xiaohongshu_creator_profile
    script: scripts/xiaohongshu_creator_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书创作者账号信息 (粉丝/关注/获赞/成长等级)"
  - name: xiaohongshu_creator_stats
    script: scripts/xiaohongshu_creator_stats.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书创作者数据总览 (观看/点赞/收藏/评论/分享/涨粉，含每日趋势)"
  - name: xiaohongshu_download
    script: scripts/xiaohongshu_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "下载小红书笔记中的图片和视频"
  - name: xiaohongshu_draft_open
    script: scripts/xiaohongshu_draft_open.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "读取一条小红书本地草稿详情"
  - name: xiaohongshu_drafts
    script: scripts/xiaohongshu_drafts.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书本地草稿箱列表"
  - name: xiaohongshu_feed
    script: scripts/xiaohongshu_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书首页推荐 Feed (reads hydrated Pinia store)"
  - name: xiaohongshu_liked
    script: scripts/xiaohongshu_liked.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书赞过笔记列表"
  - name: xiaohongshu_note
    script: scripts/xiaohongshu_note.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取小红书笔记正文和互动数据"
  - name: xiaohongshu_notifications
    script: scripts/xiaohongshu_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书通知 (mentions/likes/connections)"
  - name: xiaohongshu_saved
    script: scripts/xiaohongshu_saved.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "小红书收藏笔记列表"
  - name: xiaohongshu_search
    script: scripts/xiaohongshu_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "搜索小红书笔记"
  - name: xiaohongshu_user
    script: scripts/xiaohongshu_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Get public notes from a Xiaohongshu user profile"
  - name: xiaohongshu_whoami
    script: scripts/xiaohongshu_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in xiaohongshu account"
---

# Agent Reach · xiaohongshu

基于当前 OpenCLI 1.8.7，提供 17 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-xiaohongshu"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

国内版小红书对应 `www.xiaohongshu.com`，继续走 `opencli xiaohongshu`；国际版请求转到 `agent-reach-rednote` Skill。读取 `doctor --json` 的 `xiaohongshu` channel。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `xiaohongshu_comments` | `opencli xiaohongshu comments` | 获取小红书笔记评论（支持楼中楼子回复） |
| `xiaohongshu_creator_note_detail` | `opencli xiaohongshu creator-note-detail` | 小红书单篇笔记详情页数据 (笔记信息 + 核心/互动数据 + 观看来源 + 观众画像 + 趋势数据) |
| `xiaohongshu_creator_notes` | `opencli xiaohongshu creator-notes` | 小红书创作者笔记列表 + 每篇数据 (标题/日期/观看/点赞/收藏/评论) |
| `xiaohongshu_creator_notes_summary` | `opencli xiaohongshu creator-notes-summary` | 小红书最近笔记批量摘要 (列表 + 单篇关键数据汇总) |
| `xiaohongshu_creator_profile` | `opencli xiaohongshu creator-profile` | 小红书创作者账号信息 (粉丝/关注/获赞/成长等级) |
| `xiaohongshu_creator_stats` | `opencli xiaohongshu creator-stats` | 小红书创作者数据总览 (观看/点赞/收藏/评论/分享/涨粉，含每日趋势) |
| `xiaohongshu_download` | `opencli xiaohongshu download` | 下载小红书笔记中的图片和视频 |
| `xiaohongshu_draft_open` | `opencli xiaohongshu draft-open` | 读取一条小红书本地草稿详情 |
| `xiaohongshu_drafts` | `opencli xiaohongshu drafts` | 小红书本地草稿箱列表 |
| `xiaohongshu_feed` | `opencli xiaohongshu feed` | 小红书首页推荐 Feed (reads hydrated Pinia store) |
| `xiaohongshu_liked` | `opencli xiaohongshu liked` | 小红书赞过笔记列表 |
| `xiaohongshu_note` | `opencli xiaohongshu note` | 获取小红书笔记正文和互动数据 |
| `xiaohongshu_notifications` | `opencli xiaohongshu notifications` | 小红书通知 (mentions/likes/connections) |
| `xiaohongshu_saved` | `opencli xiaohongshu saved` | 小红书收藏笔记列表 |
| `xiaohongshu_search` | `opencli xiaohongshu search` | 搜索小红书笔记 |
| `xiaohongshu_user` | `opencli xiaohongshu user` | Get public notes from a Xiaohongshu user profile |
| `xiaohongshu_whoami` | `opencli xiaohongshu whoami` | Show the current logged-in xiaohongshu account |
