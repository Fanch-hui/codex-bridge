# 社交媒体 & 社区

国内版小红书 Xiaohongshu、国际版 Rednote、Twitter/X、B站、V2EX、Reddit、Facebook、Instagram。

## 国内版小红书 / Xiaohongshu（多后端）

国内版域名为 `www.xiaohongshu.com`，短链接为 `xhslink.com`。国内版有三个后端，**先跑 `agent-reach doctor --json` 看 `xiaohongshu` 的 `active_backend` 是哪个**，再用对应命令组。

### 后端 A：OpenCLI（桌面首选，复用浏览器登录态）

```bash
# 搜索笔记
opencli xiaohongshu search "query" -f yaml

# 读笔记正文+互动数据（用搜索结果里的完整 URL，含 xsec_token）
opencli xiaohongshu note "NOTE_URL" -f yaml

# 评论（支持楼中楼）
opencli xiaohongshu comments NOTE_ID -f yaml

# 首页推荐 feed
opencli xiaohongshu feed -f yaml

# 用户主页公开笔记
opencli xiaohongshu user USER_ID -f yaml
```

> 要求 Chrome 打开且装了 OpenCLI 扩展。报 AUTH_REQUIRED 说明浏览器里没登录小红书，让用户在 Chrome 里登录一次即可。

### 后端 B：xiaohongshu-mcp（服务器场景）

```bash
# 未登录时：先查状态，再取二维码给用户扫
mcporter call 'xiaohongshu.check_login_status()' --timeout 120000
mcporter call 'xiaohongshu.get_login_qrcode()' --timeout 120000

# 搜索
mcporter call 'xiaohongshu.search_feeds(keyword: "query")' --timeout 120000

# 笔记详情+评论（feed_id 和 xsec_token 从搜索结果取）
mcporter call 'xiaohongshu.get_feed_detail(feed_id: "...", xsec_token: "...")' --timeout 120000
```

> 首次调用会自动下载约 150MB 无头浏览器，务必带 `--timeout 120000`。未登录时 search 会挂死，先 check_login_status。

### 后端 C：xhs-cli（存量备选，上游 2026-03 起停更）

```bash
xhs search "query"          # 搜索
xhs read NOTE_ID_OR_URL     # 读笔记（必须用搜索结果中的 URL/ID，不能裸 note_id）
xhs comments NOTE_ID_OR_URL # 评论
xhs hot                     # 热门
xhs feed                    # 推荐
```

> 已知不稳定：`xhs user` / `xhs user-posts` / `xhs favorites` 可能返回 API error（上游停更无人修）。新装用户建议直接走后端 A/B。

### 通用注意事项

> **xsec_token 限制**: 小红书强制 xsec_token 机制，**不能直接用裸 note_id 去读**。正确流程：先搜索/feed 拿结果，再用结果中的完整 URL/ID 去读。三个后端都一样。
>
> **频率控制**: 高频请求（批量搜索、深翻评论）会触发验证码，平台限制无法绕过。每次操作间隔 2-3 秒。
>
> 本 Skill 提供内容读取能力，评论接口用于读取评论列表。

## 国际版小红书 / Rednote（OpenCLI）

国际版使用 `www.rednote.com`。用户明确说“国际版小红书 / Rednote / rednote.com”时，必须使用 `opencli rednote`。先检查 `agent-reach doctor --json` 中独立的 `rednote` channel；不可借用 `xiaohongshu` 的健康状态，也不可在失败时回退到国内版。

```bash
opencli rednote search "query" --limit 10 -f json
opencli rednote note "NOTE_URL" -f json
opencli rednote feed --limit 10 -f json
opencli rednote user "USER_ID_OR_URL" --limit 10 -f json
opencli rednote comments "NOTE_URL" --limit 20 --with-replies -f json
```

笔记详情和评论使用搜索、feed 或用户主页返回的完整 `www.rednote.com` URL，并保留其查询参数。国内版 URL 与国际版 URL 不能互换。

OpenCLI 复用浏览器中 Rednote 的登录态。`AUTH_REQUIRED` 时由用户在 `https://www.rednote.com` 登录；浏览器连接失败时检查 OpenCLI 扩展连接。doctor 的 adapter 检测只说明命令已安装，浏览器连通性和站点登录状态以各自检测结果为准。

## Codex Bridge 小红书 Skill Actions

调用 `run_skill_action` 时使用 `skill_name="agent-reach"`，参数放入 `arguments` 数组，例：`action_name="rednote_search"`，`arguments=["旅行", "--limit", "5", "-f", "json"]`。所有 action 的 `network_requirement` 为 `required`。

当前 OpenCLI 1.8.7 的国内版 17 个、国际版 8 个只读接口全部对应独立 action。命令名称中的连字符在 action 名中使用下划线。详细参数可通过对应 action 的 `arguments=["--help", "-f", "json"]` 获取。

### 国内版 Xiaohongshu（17 个只读接口）

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

### 国际版 Rednote（8 个只读接口）

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

`download` 读取站点媒体并写入本地文件，输出目录使用当前项目内的相对路径，仍受 Bridge 项目写权限和审批约束。`whoami`、创作者数据、通知、草稿、已赞与收藏涉及当前登录用户的内容，仅在用户明确要求读取这些内容时调用。平台登录由用户在浏览器完成。

## Twitter/X (twitter-cli)

### 稳定命令

```bash
# 首页时间线（最稳定）
twitter feed -n 20

# 读取单条推文（含回复）
twitter tweet URL_OR_ID

# 读取长文 / X Article
twitter article URL_OR_ID

# 用户时间线
twitter user-posts @username -n 20

# 用户资料
twitter user @username
```

### 可能不稳定的命令

```bash
# 搜索推文（Twitter 频繁改 GraphQL 端点，可能 404）
twitter search "query" -n 10

# likes（2024 年后只能看自己的，平台限制）
twitter likes
```

### search 失败时的重试链（按序执行，成功即停）

1. 直接重试一次（偶发失败常见）：`twitter search "query" -n 10`
2. 升级后再试：`pipx upgrade twitter-cli && twitter search "query" -n 10`
3. 换 OpenCLI 备选（桌面，复用浏览器登录态）：`opencli twitter search "query" -f yaml`
4. 都不行就改用 `twitter feed` / `twitter user-posts @somebody` 等稳定命令绕路

### 重要注意事项

> **安装**: `pipx install twitter-cli`（确保 v0.8.5+）
>
> **认证**: 推荐用 Cookie-Editor 导出后设置环境变量 `TWITTER_AUTH_TOKEN` + `TWITTER_CT0`。自动提取在 SSH/Docker/无头环境不可用。
>
> **IP 风控**: 不要在 VPS/数据中心 IP 上频繁调用，尤其是 followers/following，有封号风险。使用住宅代理或本地环境。
>
> **OpenCLI 备选**: 桌面装了 OpenCLI 的话，`opencli twitter search/article/user-posts -f yaml` 全套可用（浏览器登录态，无需 cookie 环境变量）。
>
> **输出格式**: 建议用 `--yaml` 或 `--json` 获得结构化输出，对 AI agent 更友好。

## B站 / Bilibili

> ⚠️ **不要用 yt-dlp 读 B站**（风控已全面 412 拦截，实测无解）。用 bili-cli / OpenCLI。

```bash
# 搜索 / 热门 / 视频详情（bili-cli，只读无需登录）
bili search "query" --type video -n 5
bili hot -n 10
bili video BVxxx

# 字幕（OpenCLI，需桌面 Chrome）
opencli bilibili subtitle BVxxx
```

> 详细命令（音频转写、API 直连兜底）见 [references/video.md](video.md)。

## V2EX (公开 API)

无需认证，直接调用公开 API。

### 热门主题

```bash
curl -s "https://www.v2ex.com/api/topics/hot.json" -H "User-Agent: agent-reach/1.0"
```

### 节点主题

```bash
# node_name 如: python, tech, jobs, qna, programmers
curl -s "https://www.v2ex.com/api/topics/show.json?node_name=python&page=1" -H "User-Agent: agent-reach/1.0"
```

### 主题详情

```bash
# topic_id 从 URL 获取，如 https://www.v2ex.com/t/1234567
curl -s "https://www.v2ex.com/api/topics/show.json?id=TOPIC_ID" -H "User-Agent: agent-reach/1.0"
```

### 主题回复

```bash
curl -s "https://www.v2ex.com/api/replies/show.json?topic_id=TOPIC_ID&page=1" -H "User-Agent: agent-reach/1.0"
```

### 用户信息

```bash
curl -s "https://www.v2ex.com/api/members/show.json?username=USERNAME" -H "User-Agent: agent-reach/1.0"
```

### Python 调用示例

```python
from agent_reach.channels.v2ex import V2EXChannel

ch = V2EXChannel()

# 获取热门帖子
topics = ch.get_hot_topics(limit=10)
for t in topics:
    print(f"[{t['node_title']}] {t['title']} ({t['replies']} 回复)")

# 获取节点帖子
node_topics = ch.get_node_topics("python", limit=5)

# 获取帖子详情 + 回复
topic = ch.get_topic(1234567)
print(topic["title"], "—", topic["author"])

# 获取用户信息
user = ch.get_user("Livid")
```

> **节点列表**: https://www.v2ex.com/planes

## Reddit（多后端，必须登录态）

**Reddit 没有零配置路径**：匿名 `.json` 端点已被封（403），官方 API 自 2025-11 起人工审批基本不批。两个后端都靠登录态，先跑 `agent-reach doctor --json` 看 reddit 的 `active_backend`。中国大陆访问需代理。

### 后端 A：OpenCLI（桌面首选，复用浏览器登录态）

```bash
# 搜索帖子
opencli reddit search "query" -f yaml

# 读帖子全文 + 评论
opencli reddit read POST_ID -f yaml

# 浏览 subreddit / 热门 / Popular
opencli reddit subreddit LocalLLaMA -f yaml
opencli reddit hot -f yaml
opencli reddit popular -f yaml

# subreddit 元信息（订阅数、简介）
opencli reddit subreddit-info LocalLLaMA -f yaml
```

> 要求 Chrome 打开且浏览器里登录过 reddit.com。

### 后端 B：rdt-cli（存量/服务器备选，上游 2026-03 起停更）

```bash
rdt search "query" --limit 10   # 搜索帖子
rdt read POST_ID                # 读帖子全文 + 评论
rdt sub python --limit 20       # 浏览 subreddit
rdt popular --limit 10          # 浏览热门
rdt all --limit 10              # 浏览 /r/all
```

> **安装**: `pipx install 'git+https://github.com/public-clis/rdt-cli.git'`（PyPI 版本落后，需从 GitHub 装 v0.4.2+）。先 `rdt login` 才能搜索和阅读（服务器无浏览器时手动写 Cookie，见 doctor 提示）。
> 建议使用 `--yaml` 输出，对 AI agent 更友好。

### 高级选项：官方 API + PRAW（仅限已有凭证的用户）

2025-11 前注册过 Reddit script app（持有 client_id/client_secret）的用户可以用 PRAW 走官方 API（100 QPM 免费）。新申请需人工审批且个人项目基本不批，**不要推荐新用户走这条路**。

## Facebook（OpenCLI，必须登录态）

Facebook 走 OpenCLI，复用用户 Chrome 里的 facebook.com 登录态。先跑 `agent-reach doctor --json` 看 facebook 的 `active_backend`，正常应为 `OpenCLI`。不要推荐 Jina/Exa/Graph API 作为默认路径。

```bash
# 搜索用户 / 主页 / 帖子
opencli facebook search "query" -f yaml

# 用户或主页信息
opencli facebook profile zuck -f yaml

# 当前账号 News Feed
opencli facebook feed --limit 10 -f yaml

# 当前账号可见的群组列表/最近动态
opencli facebook groups --limit 20 -f yaml
```

> 要求 Chrome 打开且装了 OpenCLI 扩展，并已登录 facebook.com。Facebook Groups 当前只承诺读取当前账号可见的群组列表/最近动态，不承诺任意群帖子和评论 API。

## Instagram（OpenCLI，必须登录态）

Instagram 走 OpenCLI，复用用户 Chrome 里的 instagram.com 登录态。先跑 `agent-reach doctor --json` 看 instagram 的 `active_backend`，正常应为 `OpenCLI`。不要默认恢复 instaloader；历史上 cookies/401/429 不稳定。

```bash
# 搜索用户（不是全站帖子关键词搜索）
opencli instagram search "query" -f yaml

# 用户 Profile
opencli instagram profile nasa -f yaml

# 用户最近帖子
opencli instagram user nasa --limit 12 -f yaml

# Explore / Discover
opencli instagram explore --limit 20 -f yaml

# 当前账号收藏
opencli instagram saved --limit 20 -f yaml
```

> 要求 Chrome 打开且装了 OpenCLI 扩展，并已登录 instagram.com。`instagram search` 是用户搜索；读帖子需要先确定 username，再用 `instagram user USERNAME`。若出现 429 / login required，先让用户在 Chrome 里重新登录并降低频率。
