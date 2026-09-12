---
name: agent-reach-xueqiu
description: "Agent Reach 的 xueqiu 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: xueqiu_comments
    script: scripts/xueqiu_comments.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取单只股票的讨论动态"
  - name: xueqiu_earnings_date
    script: scripts/xueqiu_earnings_date.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取股票预计财报发布日期（公司大事）"
  - name: xueqiu_feed
    script: scripts/xueqiu_feed.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球首页时间线（关注用户的动态）"
  - name: xueqiu_fund_holdings
    script: scripts/xueqiu_fund_holdings.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取蛋卷基金持仓明细（可用 --account 按子账户过滤）"
  - name: xueqiu_fund_snapshot
    script: scripts/xueqiu_fund_snapshot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取蛋卷基金快照（总资产、子账户、持仓，推荐 -f json 输出）"
  - name: xueqiu_groups
    script: scripts/xueqiu_groups.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球自选股分组列表（含模拟组合）"
  - name: xueqiu_hot
    script: scripts/xueqiu_hot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球热门动态"
  - name: xueqiu_hot_stock
    script: scripts/xueqiu_hot_stock.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球热门股票榜"
  - name: xueqiu_kline
    script: scripts/xueqiu_kline.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球股票K线（历史行情）数据"
  - name: xueqiu_search
    script: scripts/xueqiu_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "搜索雪球股票（代码或名称）"
  - name: xueqiu_stock
    script: scripts/xueqiu_stock.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球股票实时行情"
  - name: xueqiu_watchlist
    script: scripts/xueqiu_watchlist.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "获取雪球自选股/模拟组合股票列表"
  - name: xueqiu_whoami
    script: scripts/xueqiu_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in xueqiu account"
---

# Agent Reach · xueqiu

基于当前 OpenCLI 1.8.7，提供 13 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-xueqiu"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `xueqiu_comments` | `opencli xueqiu comments` | 获取单只股票的讨论动态 |
| `xueqiu_earnings_date` | `opencli xueqiu earnings-date` | 获取股票预计财报发布日期（公司大事） |
| `xueqiu_feed` | `opencli xueqiu feed` | 获取雪球首页时间线（关注用户的动态） |
| `xueqiu_fund_holdings` | `opencli xueqiu fund-holdings` | 获取蛋卷基金持仓明细（可用 --account 按子账户过滤） |
| `xueqiu_fund_snapshot` | `opencli xueqiu fund-snapshot` | 获取蛋卷基金快照（总资产、子账户、持仓，推荐 -f json 输出） |
| `xueqiu_groups` | `opencli xueqiu groups` | 获取雪球自选股分组列表（含模拟组合） |
| `xueqiu_hot` | `opencli xueqiu hot` | 获取雪球热门动态 |
| `xueqiu_hot_stock` | `opencli xueqiu hot-stock` | 获取雪球热门股票榜 |
| `xueqiu_kline` | `opencli xueqiu kline` | 获取雪球股票K线（历史行情）数据 |
| `xueqiu_search` | `opencli xueqiu search` | 搜索雪球股票（代码或名称） |
| `xueqiu_stock` | `opencli xueqiu stock` | 获取雪球股票实时行情 |
| `xueqiu_watchlist` | `opencli xueqiu watchlist` | 获取雪球自选股/模拟组合股票列表 |
| `xueqiu_whoami` | `opencli xueqiu whoami` | Show the current logged-in xueqiu account |
