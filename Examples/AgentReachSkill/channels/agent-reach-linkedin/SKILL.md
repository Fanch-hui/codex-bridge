---
name: agent-reach-linkedin
description: "Agent Reach 的 linkedin 渠道只读接口。用户需要通过 Codex Bridge run_skill_action 直接读取此渠道内容时使用；平台后端路由由 Agent Reach 主 Skill 提供。"
actions:
  - name: linkedin_company
    script: scripts/linkedin_company.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read a LinkedIn company page: industry, size, HQ, founded, website, followers, about"
  - name: linkedin_connections
    script: scripts/linkedin_connections.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List your LinkedIn first-degree connections (name, headline, profile URL)"
  - name: linkedin_inbox
    script: scripts/linkedin_inbox.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List LinkedIn messaging inbox conversations and unread messages"
  - name: linkedin_job_detail
    script: scripts/linkedin_job_detail.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read one LinkedIn job page with description, apply URL, workplace type, applicants, and company metadata"
  - name: linkedin_jobs_preferences
    script: scripts/linkedin_jobs_preferences.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read visible LinkedIn Jobs preferences and alert settings without changing them"
  - name: linkedin_people_search
    script: scripts/linkedin_people_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search standard LinkedIn (not Sales Navigator) for people by keyword. Each invocation consumes against LinkedIn's monthly Commercial Use Limit on people search; throttle accordingly."
  - name: linkedin_post_analytics
    script: scripts/linkedin_post_analytics.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Summarize raw visible LinkedIn post counters without custom scoring or classification"
  - name: linkedin_posts
    script: scripts/linkedin_posts.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Export visible posts from a LinkedIn profile activity page with engagement metrics"
  - name: linkedin_profile_analytics
    script: scripts/linkedin_profile_analytics.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read visible LinkedIn profile dashboard metrics such as profile views, post impressions, and search appearances"
  - name: linkedin_profile_experience
    script: scripts/linkedin_profile_experience.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read visible LinkedIn profile experience entries with titles, dates, locations, skills, media, and URLs"
  - name: linkedin_profile_projects
    script: scripts/linkedin_profile_projects.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read visible LinkedIn profile projects with descriptions, dates, skills, media, and URLs"
  - name: linkedin_profile_read
    script: scripts/linkedin_profile_read.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read visible LinkedIn profile sections: headline, About, experience, education, services, and featured sections"
  - name: linkedin_salesnav_inbox
    script: scripts/linkedin_salesnav_inbox.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List LinkedIn Sales Navigator message conversations with API pagination"
  - name: linkedin_salesnav_search
    script: scripts/linkedin_salesnav_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search LinkedIn Sales Navigator for people leads by keyword"
  - name: linkedin_salesnav_thread
    script: scripts/linkedin_salesnav_thread.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Return full Sales Navigator message history for a thread id, Sales Navigator inbox URL, lead URL, recipient urn, or exact recipient name"
  - name: linkedin_search
    script: scripts/linkedin_search.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Search LinkedIn jobs"
  - name: linkedin_sent_invitations
    script: scripts/linkedin_sent_invitations.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "List pending LinkedIn sent invitations for CRM reconciliation"
  - name: linkedin_services_read
    script: scripts/linkedin_services_read.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read LinkedIn Services page details including services, overview, availability, pricing, and media titles/descriptions"
  - name: linkedin_thread_snapshot
    script: scripts/linkedin_thread_snapshot.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Load a LinkedIn messaging thread, scroll for available history, and return a full context snapshot"
  - name: linkedin_timeline
    script: scripts/linkedin_timeline.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Read LinkedIn home timeline posts"
  - name: linkedin_whoami
    script: scripts/linkedin_whoami.sh
    interpreter: /bin/sh
    network_requirement: required
    description: "Show the current logged-in linkedin account"
---

# Agent Reach · linkedin

基于当前 OpenCLI 1.8.7，提供 21 个只读接口。

通过 `run_skill_action` 调用：`skill_name="agent-reach-linkedin"`，`project_id` 使用 `list_projects` 返回的不透明 ID，参数放入 `arguments` 字符串数组。

读取参数说明：选择目标 action 并传入 `arguments=["--help", "-f", "json"]`。所有 action 需要网络，执行沿用 Bridge 项目权限、本机审批和有界进程管理。

登录由用户在浏览器完成。通知、个人资料、私信、草稿、已赞/收藏等用户专属内容，只在用户明确要求时读取。下载输出使用项目内相对路径。

| Action | 固定命令 | 用途 |
|--------|----------|------|
| `linkedin_company` | `opencli linkedin company` | Read a LinkedIn company page: industry, size, HQ, founded, website, followers, about |
| `linkedin_connections` | `opencli linkedin connections` | List your LinkedIn first-degree connections (name, headline, profile URL) |
| `linkedin_inbox` | `opencli linkedin inbox` | List LinkedIn messaging inbox conversations and unread messages |
| `linkedin_job_detail` | `opencli linkedin job-detail` | Read one LinkedIn job page with description, apply URL, workplace type, applicants, and company metadata |
| `linkedin_jobs_preferences` | `opencli linkedin jobs-preferences` | Read visible LinkedIn Jobs preferences and alert settings without changing them |
| `linkedin_people_search` | `opencli linkedin people-search` | Search standard LinkedIn (not Sales Navigator) for people by keyword. Each invocation consumes against LinkedIn's monthly Commercial Use Limit on people search; throttle accordingly. |
| `linkedin_post_analytics` | `opencli linkedin post-analytics` | Summarize raw visible LinkedIn post counters without custom scoring or classification |
| `linkedin_posts` | `opencli linkedin posts` | Export visible posts from a LinkedIn profile activity page with engagement metrics |
| `linkedin_profile_analytics` | `opencli linkedin profile-analytics` | Read visible LinkedIn profile dashboard metrics such as profile views, post impressions, and search appearances |
| `linkedin_profile_experience` | `opencli linkedin profile-experience` | Read visible LinkedIn profile experience entries with titles, dates, locations, skills, media, and URLs |
| `linkedin_profile_projects` | `opencli linkedin profile-projects` | Read visible LinkedIn profile projects with descriptions, dates, skills, media, and URLs |
| `linkedin_profile_read` | `opencli linkedin profile-read` | Read visible LinkedIn profile sections: headline, About, experience, education, services, and featured sections |
| `linkedin_salesnav_inbox` | `opencli linkedin salesnav-inbox` | List LinkedIn Sales Navigator message conversations with API pagination |
| `linkedin_salesnav_search` | `opencli linkedin salesnav-search` | Search LinkedIn Sales Navigator for people leads by keyword |
| `linkedin_salesnav_thread` | `opencli linkedin salesnav-thread` | Return full Sales Navigator message history for a thread id, Sales Navigator inbox URL, lead URL, recipient urn, or exact recipient name |
| `linkedin_search` | `opencli linkedin search` | Search LinkedIn jobs |
| `linkedin_sent_invitations` | `opencli linkedin sent-invitations` | List pending LinkedIn sent invitations for CRM reconciliation |
| `linkedin_services_read` | `opencli linkedin services-read` | Read LinkedIn Services page details including services, overview, availability, pricing, and media titles/descriptions |
| `linkedin_thread_snapshot` | `opencli linkedin thread-snapshot` | Load a LinkedIn messaging thread, scroll for available history, and return a full context snapshot |
| `linkedin_timeline` | `opencli linkedin timeline` | Read LinkedIn home timeline posts |
| `linkedin_whoami` | `opencli linkedin whoami` | Show the current logged-in linkedin account |
