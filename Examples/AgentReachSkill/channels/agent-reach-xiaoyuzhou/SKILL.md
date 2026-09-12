---
name: agent-reach-xiaoyuzhou
description: "Agent Reach 的 xiaoyuzhou 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: xiaoyuzhou_download
    script: scripts/xiaoyuzhou_download.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download Xiaoyuzhou episode audio"
  - name: xiaoyuzhou_episode
    script: scripts/xiaoyuzhou_episode.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "View details of a Xiaoyuzhou podcast episode"
  - name: xiaoyuzhou_podcast
    script: scripts/xiaoyuzhou_podcast.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "View a Xiaoyuzhou podcast profile"
  - name: xiaoyuzhou_podcast_episodes
    script: scripts/xiaoyuzhou_podcast_episodes.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List episodes of a Xiaoyuzhou podcast"
  - name: xiaoyuzhou_transcript
    script: scripts/xiaoyuzhou_transcript.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Download Xiaoyuzhou transcript as JSON and text (requires local credentials)"
---

# Agent Reach · xiaoyuzhou

基于当前 OpenCLI 1.8.7，提供 5 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-xiaoyuzhou"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `xiaoyuzhou_download` | `opencli xiaoyuzhou download` | Download Xiaoyuzhou episode audio |
| `xiaoyuzhou_episode` | `opencli xiaoyuzhou episode` | View details of a Xiaoyuzhou podcast episode |
| `xiaoyuzhou_podcast` | `opencli xiaoyuzhou podcast` | View a Xiaoyuzhou podcast profile |
| `xiaoyuzhou_podcast_episodes` | `opencli xiaoyuzhou podcast-episodes` | List episodes of a Xiaoyuzhou podcast |
| `xiaoyuzhou_transcript` | `opencli xiaoyuzhou transcript` | Download Xiaoyuzhou transcript as JSON and text (requires local credentials) |
