# OpenCLI 渠道只读接口

当前 OpenCLI 1.8.7 中，Agent Reach 已收录平台共有 14 个对应 adapter、159 个只读接口，按渠道提供独立 Skill。Agent Reach 的 `rss` 和 `exa_search` 使用各自原有 API / CLI 路径，OpenCLI 当前没有同名 adapter。

每个表中的 Skill 均通过 Codex Bridge `run_skill_action` 执行。使用 `list_skills` 获取 action 列表，或 `read_skill` 读取该渠道 Skill 的完整接口表。`arguments=["--help", "-f", "json"]` 可读取选定 action 的参数定义。

| 渠道 | skill_name | action 数 |
|------|------------|-----------|
| bilibili | `agent-reach-bilibili` | 16 |
| facebook | `agent-reach-facebook` | 11 |
| github | `agent-reach-github` | 1 |
| instagram | `agent-reach-instagram` | 9 |
| linkedin | `agent-reach-linkedin` | 21 |
| reddit | `agent-reach-reddit` | 15 |
| rednote | `agent-reach-rednote` | 8 |
| twitter | `agent-reach-twitter` | 20 |
| v2ex | `agent-reach-v2ex` | 11 |
| web | `agent-reach-web` | 1 |
| xiaohongshu | `agent-reach-xiaohongshu` | 17 |
| xiaoyuzhou | `agent-reach-xiaoyuzhou` | 5 |
| xueqiu | `agent-reach-xueqiu` | 13 |
| youtube | `agent-reach-youtube` | 11 |

示例：`skill_name="agent-reach-youtube"`、`action_name="youtube_transcript"`，`arguments` 为该命令的参数数组。

主 Skill `agent-reach` 保留既有 action 名称，并提供国内版小红书、国际版 Rednote 的全部只读 action。跨平台操作先选择明确渠道，再读取该渠道的接口；国际版 Rednote 始终使用 `rednote` channel 和 `www.rednote.com`。

接口清单在安装时固定，新增上游命令需核对其读写语义后更新。所有 action 都声明 `network_requirement: required`。
