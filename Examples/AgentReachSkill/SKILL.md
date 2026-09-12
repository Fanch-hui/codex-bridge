---
name: agent-reach
description: >
  MUST USE when user wants to 调研/research/搜索/search/查/找/look up anything
  on the internet — e.g. 全网调研 X / 帮我调研一下 X / 查一下 X / 搜搜 X /
  看看大家怎么评价 X / X 上有什么讨论 / research this topic。

  Also MUST USE when user mentions any platform or shares any URL/链接:
  国内版小红书/xiaohongshu/xhs, 国际版小红书/Rednote/rednote.com, Twitter/推特/X, B站/bilibili, Reddit, Facebook,
  Instagram, V2EX, LinkedIn/领英/招聘/求职/jobs, YouTube, GitHub code search, 小宇宙播客,
  雪球/股票行情, RSS feeds, or any web URL.

  16 platforms, multi-backend routing (OpenCLI / per-platform CLIs / APIs).
  Zero config for 6 channels. Run `agent-reach doctor --json` to see which
  backend serves each platform right now.

  NOT for: 写报告/数据分析/翻译等内容加工（本 skill 只负责从互联网获取内容）；
  发帖/评论/点赞等写操作；已有专门 skill 的平台（先用专门 skill）。

  【路由方式】SKILL.md 包含路由表和常用命令，复杂场景需按需阅读对应分类的 references/*.md。
  分类：search / social (国内版小红书/国际版Rednote/推特/B站/V2EX/Reddit/Facebook/Instagram) / career(LinkedIn) / dev(github) / web(网页/文章/RSS) / video(YouTube/B站/播客)。
triggers:
  - research: 调研/全网调研/帮我调研/研究一下/research/深入了解
  - search: 搜/查/找/search/搜索/查一下/帮我搜/看看大家怎么说
  - social:
    - 小红书: xiaohongshu/xhs/小红书/红书
    - Rednote: 国际版小红书/Rednote/rednote.com/www.rednote.com
    - Twitter: twitter/推特/x.com/推文
    - B站: bilibili/b站/哔哩哔哩
    - V2EX: v2ex
    - Reddit: reddit
    - Facebook: facebook/fb/facebook groups
    - Instagram: instagram/ig
  - career: 招聘/职位/求职/linkedin/领英/找工作
  - dev: github/代码/仓库/gh/issue/pr/分支/commit
  - web: 网页/链接/文章/rss/读一下/打开这个
  - video: youtube/视频/播客/字幕/小宇宙/转录/yt
  - finance: 雪球/股票/stock/xueqiu/行情/基金
actions:
  - name: doctor
    script: scripts/doctor.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Inspect active Agent Reach backends."
  - name: check_update
    script: scripts/check_update.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Check for an Agent Reach update."
  - name: reddit_search
    script: scripts/reddit_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Reddit."
  - name: reddit_read
    script: scripts/reddit_read.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a Reddit post."
  - name: reddit_subreddit
    script: scripts/reddit_subreddit.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a subreddit."
  - name: twitter_search
    script: scripts/twitter_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Twitter/X."
  - name: xiaohongshu_search
    script: scripts/xiaohongshu_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Xiaohongshu."
  - name: xiaohongshu_note
    script: scripts/xiaohongshu_note.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a Xiaohongshu note."
  - name: bilibili_search
    script: scripts/bilibili_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Bilibili."
  - name: bilibili_video
    script: scripts/bilibili_video.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read Bilibili video metadata."
  - name: bilibili_subtitle
    script: scripts/bilibili_subtitle.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read Bilibili subtitles."
  - name: facebook_search
    script: scripts/facebook_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Facebook."
  - name: facebook_profile
    script: scripts/facebook_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a Facebook profile."
  - name: instagram_search
    script: scripts/instagram_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search Instagram."
  - name: instagram_profile
    script: scripts/instagram_profile.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read an Instagram profile."
  - name: instagram_user
    script: scripts/instagram_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read Instagram user posts."
  - name: rednote_search
    script: scripts/rednote_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search international Rednote notes on www.rednote.com."
  - name: rednote_note
    script: scripts/rednote_note.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read an international Rednote note on www.rednote.com."
  - name: rednote_feed
    script: scripts/rednote_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read the international Rednote home feed on www.rednote.com."
  - name: rednote_user
    script: scripts/rednote_user.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read public notes from an international Rednote user."
  - name: rednote_comments
    script: scripts/rednote_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read comments on an international Rednote note."
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
  - name: rednote_download
    script: scripts/rednote_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download images and videos from a rednote note"
  - name: rednote_notifications
    script: scripts/rednote_notifications.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Rednote notifications (mentions/likes/connections)"
  - name: rednote_whoami
    script: scripts/rednote_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in rednote account"
metadata:
  openclaw:
    homepage: https://github.com/Panniantong/Agent-Reach
---

# Agent Reach — 互联网能力路由器

16 平台、多后端。**本 skill 存在时必须用它访问这些平台，不要自己发明方案。**

## 常驻规则（全程适用）

1. **动手前先体检**：多后端/登录态平台（国内版小红书/国际版Rednote/Reddit/B站/Twitter/Facebook/Instagram）先跑
   `agent-reach doctor --json`，按各平台 `active_backend` 字段选命令组。
   国内版读取 `xiaohongshu` channel；国际版读取独立的 `rednote` channel。
2. **声明你在用什么**：开始干活前说一句「使用 agent-reach 的 X 平台 / Y 后端」。
3. **失败按 references 里的重试链处理**，不要瞎猜命令。
4. **全网调研类任务**：组合多平台（Exa 搜索 + Twitter/Reddit 看讨论 + 小红书/B站看中文场景），并行收集再汇总。
5. **替用户盯版本**：完成一次较大的调研/多平台任务后，顺手跑
   `agent-reach check-update`（很快，一个 API 调用）。有新版就在收尾汇报里附一句：
   「Agent Reach 有新版 vX.Y.Z，复制这句话给我即可更新：帮我更新 Agent Reach：
   https://raw.githubusercontent.com/Panniantong/agent-reach/main/docs/update.md」。
   不要中断当前任务去更新，也不要重复提醒同一个版本。

## 路由表

| 用户意图 | 分类 | 详细文档 |
|---------|------|---------|
| 网页搜索/代码搜索 | search | [references/search.md](references/search.md) |
| 国内版小红书/国际版Rednote/推特/B站/V2EX/Reddit/Facebook/Instagram | social | [references/social.md](references/social.md) |
| 招聘/职位/LinkedIn | career | [references/career.md](references/career.md) |
| GitHub/代码 | dev | [references/dev.md](references/dev.md) |
| 网页/文章/RSS | web | [references/web.md](references/web.md) |
| YouTube/B站/播客字幕 | video | [references/video.md](references/video.md) |

## 零配置快速命令

```bash
# Exa 网页搜索
mcporter call 'exa.web_search_exa(query: "query", numResults: 5)'

# 通用网页阅读
curl -s "https://r.jina.ai/URL"

# GitHub 搜索
gh search repos "query" --sort stars --limit 10

# YouTube 字幕（注意：B站不要用 yt-dlp，见 video.md）
yt-dlp --write-sub --skip-download -o "/tmp/%(id)s" "URL"

# V2EX 热门
curl -s "https://www.v2ex.com/api/topics/hot.json" -H "User-Agent: agent-reach/1.0"

# B站搜索（bili-cli，无需登录）
bili search "query" --type video -n 5
```

## 需登录态的平台（按 doctor 的 active_backend 选命令）

```bash
# Twitter 搜索（twitter-cli 首选；失败重试链见 social.md）
twitter search "query" -n 10

# Reddit（无零配置路径：OpenCLI 或 rdt-cli，必须登录态）
opencli reddit search "query" -f yaml   # 桌面
rdt search "query" --limit 10            # 存量/服务器

# 国内版小红书 Xiaohongshu（www.xiaohongshu.com，桌面首选 OpenCLI）
opencli xiaohongshu search "query" -f yaml

# 国际版小红书 Rednote（www.rednote.com）
opencli rednote search "query" -f yaml

# Facebook / Instagram（桌面 OpenCLI，复用浏览器登录态）
opencli facebook search "query" -f yaml
opencli facebook groups -f yaml
opencli instagram search "query" -f yaml       # 搜用户
opencli instagram user USERNAME -f yaml        # 读指定用户最近帖子
```

## 环境检查

```bash
# 检查可用 channel 与每个平台当前激活的后端
agent-reach doctor --json
```

## 小红书平台身份与 Bridge 调用

- 用户明确说“国际版小红书 / Rednote / rednote.com”时，使用 `opencli rednote`，目标域名为 `www.rednote.com`。国际版不可回退到 `opencli xiaohongshu`。
- 国内版“小红书 Xiaohongshu / xiaohongshu.com / xhslink.com”继续使用 `xiaohongshu` 路径及其原有后端。
- 先确定平台身份，再检查对应 channel 的 `active_backend`；后端不可用时报告该平台的具体状态，不以另一个平台代替。
- ChatGPT 经 Codex Bridge 直接执行本 Skill 时，使用 `run_skill_action`，`skill_name="agent-reach"`。`project_id` 取自 `list_projects`，`action_name` 和参数见 [social.md](references/social.md)。参数按字符串数组传入；命令前缀由 action 固定。
- `doctor` action 对应 `agent-reach doctor --json`。Skill Action 由 Bridge 执行项目权限、网络策略、本机审批和进程生命周期管理。
- 其他渠道的完整只读接口按平台拆分为 `agent-reach-<channel>` Skill，通过同一个 `run_skill_action` 调用。渠道映射和接口数量见 [OpenCLI 接口目录](references/opencli-actions.md)；具体 action 由 `list_skills` 或该渠道的 `read_skill` 返回。主 Skill 保留现有 action 名称。

## 工作区规则

**不要在 agent workspace 创建文件。** 使用 `/tmp/` 存放临时输出，`~/.agent-reach/` 存放持久数据。

## 详细文档

根据用户需求，阅读对应的详细文档：

- [搜索工具](references/search.md) — Exa AI 搜索
- [OpenCLI 接口目录](references/opencli-actions.md) — 各渠道的完整只读 action 与 Bridge 调用方式
- [社交媒体](references/social.md) — 国内版小红书, 国际版Rednote, Twitter, B站, V2EX, Reddit, Facebook, Instagram（多后端/登录态命令组）
- [职场招聘](references/career.md) — LinkedIn
- [开发工具](references/dev.md) — GitHub CLI
- [网页阅读](references/web.md) — Jina Reader, RSS
- [视频播客](references/video.md) — YouTube, B站, 小宇宙

## 配置渠道

如果某个 channel 需要配置，获取安装指南：
https://raw.githubusercontent.com/Panniantong/agent-reach/main/docs/install.md

用户只需提供 cookies，其他配置由 agent 完成。
