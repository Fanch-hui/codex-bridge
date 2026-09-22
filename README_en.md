# Codex Bridge

[简体中文](./README.md) · [English](./README_en.md)

[Published on the official MCP Registry.](https://registry.modelcontextprotocol.io/v0.1/servers/io.github.yeyuancc0-glitch%2Fcodex-bridge/versions/latest)

Codex Bridge is a self-hosted desktop app and background service that connects ChatGPT on the web, Qwen Studio, and a local workbench to explicitly authorized projects. It manages tasks, approvals, and conversations across Codex, OpenCode, DeepSeek Harness, and Antigravity.

macOS and Windows share the Swift core and desktop UI. Project permissions, configuration, and task history are stored locally. Requests are sent to the services you choose when using ChatGPT or a model API.

The current release is `v1.1.2`.

## Download and install

Get the latest version from [GitHub Releases](https://github.com/yeyuancc0-glitch/codex-bridge/releases/latest).

| Platform | v1.1.2 package | Installation |
| --- | --- | --- |
| macOS 14+, Apple Silicon | `CodexBridge-1.1.2-macos-arm64.dmg` | Open the DMG and drag the app to Applications |
| Windows x64 | `CodexBridge-Windows-x64-1.1.2-Setup.exe` | Run the installer and choose an installation folder |
| Windows x64, portable | `codex-bridge-windows-x64.zip` | Extract the complete archive and run `codex-bridge-windows-app.exe` |

The macOS package is ad-hoc signed and is not Apple-notarized. If macOS blocks the app, allow it in System Settings → Privacy & Security. Windows requires WebView2 Runtime; the app reports a missing runtime.

Upgrades preserve application data and the embedded browser profile. Closing the Windows main window keeps the tray icon; use the tray menu to exit.

Versions with the built-in updater check GitHub once at startup and show available updates on the overview page. Choose Update to download and install; installation waits for active work to finish, then restarts the app. After every update, refresh the plugin in ChatGPT to prevent stale caches (see [ChatGPT Guide](./docs/CHATGPT_DEVELOPER_MODE.md#8-版本更新后在-chatgpt-刷新插件防旧版缓存)). Settings also provides a manual check. Older versions need one manual installation of an updater-enabled release.

## Screenshots and task demo

Recorded on macOS; Windows uses the same shared product UI. This 15-second demo follows ChatGPT submitting “你好” → local approval → Codex execution → the response in the workbench.

<img src="./docs/assets/workbench-demo.gif" width="640" alt="Full animated demo: ChatGPT submission, local approval, and the Codex response">

<details>
<summary>View the task approval screen</summary>

The local approval card shows the pending operation; choosing “Allow once” continues the task.

<img src="./docs/assets/task-approval.jpg" width="640" alt="Task approval screen">

</details>

<details>
<summary>View the overview and settings screens</summary>

The overview shows the background service, local MCP channel, Secure Tunnel, Agent engines, and recent task status.

<img src="./docs/assets/overview.png" width="640" alt="Codex Bridge overview">

The Agent settings show models, reasoning levels, and permissions for Codex, Antigravity CLI, and DeepSeek Harness.

<img src="./docs/assets/agent-models.png" width="640" alt="Agent models and permissions">

OpenCode model and permission settings, followed by Direct Workspace command mode, allowlist, and blocklist.

<img src="./docs/assets/direct-workspace.png" width="640" alt="Direct Workspace settings">

The approvals and MCP settings page shows Direct operation and remote task launch policies, along with custom GPT/Qwen MCP instructions.

<img src="./docs/assets/approvals.png" width="640" alt="Approvals and MCP settings">

</details>

## User guides

- [Complete user guide (Chinese)](./docs/USER_GUIDE.md)
- [ChatGPT / Tunnel / OpenAI Runtime API Key (Chinese)](./docs/CHATGPT_DEVELOPER_MODE.md)
- [DeepSeek Harness installation and API configuration](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE_en.md)
- [OpenCode (Chinese)](./docs/OPENCODE_CONNECTION_GUIDE.md) · [Antigravity (Chinese)](./docs/ANTIGRAVITY_CONNECTION_GUIDE.md)
- [MCPB client connection and Registry publishing (Chinese)](./docs/MCP_REGISTRY.md)

## First setup

1. Open the app and confirm that the background service is connected. Approve the macOS background item if prompted.
2. Register a local project and set its read, write, and network permissions.
3. Bridge scans for local agents once on first initialization and saves the catalog. Connect a discovered agent from the Connections page; after installing another agent, click **Scan Agents** to update the catalog. Codex uses the local Codex execution channel. DeepSeek Harness supports configuring its service URL and API key in the app.
4. Select a project and `Read Only` or `Write` in the workbench.
5. Connect ChatGPT through OpenAI Secure MCP Tunnel (requires ChatGPT Plus or higher, or Team subscription), or Qwen Studio through loopback HTTP MCP. The Connections page provides configuration controls.
6. Submit a task locally or call `submit_task` from the connected chat client. Follow output, tools, approvals, and structured questions in the workbench.

Credentials are managed through the operating system credential store. Remove credentials before sharing configuration, logs, or screenshots.

## Capabilities

- **Codex:** Thread/Turn, streaming output, approvals, structured questions, steer, and interrupt.
- **OpenCode:** ACP, model and reasoning options, permissions, and conversation continuation.
- **DeepSeek Harness:** ACP capability probing, live model catalogs, search configuration, MCP servers, and persistent sessions.
- **Antigravity:** CLI integration, native permission policies, execution progress, and conversation continuation.
- **Workbench:** project sessions grouped by agent, history paging, tool cards, task controls, and approvals.
- **Direct Workspace:** controlled file access, patches, command execution, and Git operations.
- **Skills:** local discovery, read-only inspection, and explicit actions.

Effective capabilities depend on the agent, its connection probe, and project permissions. Requests without `project_id` use the workbench default project; requests without `provider_id` use Codex.

## Task concurrency limits

macOS and Windows use the same task concurrency rules:

| Scope | Limit |
| --- | --- |
| Same project | One active write task, shared across all agents |
| Different projects | Write tasks can run concurrently, subject to the selected agent's limits |
| Codex | Up to four concurrent execution sessions, counting read-only and write sessions together |
| External agents | Bridge imposes no single global concurrency cap; project write slots, provider limits, and local resources still apply |

Write tasks awaiting local approval, starting, running, waiting for permission approval, or in an unknown state hold the project's write slot. At capacity, a new task is rejected or fails to start and must be retried after a slot becomes available; it is not automatically queued. Stored task history does not count toward execution concurrency limits.

## Architecture

```text
ChatGPT Web ── Secure MCP Tunnel ─┐
Qwen Studio ── localhost MCP ────┼─► Codex Bridge Service
Desktop App ── local IPC ────────┘   ├─ Project policy and approvals
                                    ├─ Tasks, conversations, SQLite
                                    ├─ Codex / OpenCode / DSH / AGY
                                    └─ Direct Workspace / Skills
```

macOS uses WKWebView and XPC; Windows uses WebView2 and named pipes. Both use `BridgeDesktopUI` and `BridgeServiceAppCore`. Windows uses state revisions, page caches, and incremental message rendering while active conversations retain their independent streaming subscriptions.

## Build from source

The default development branch is `win`.

```bash
git clone --branch win https://github.com/yeyuancc0-glitch/codex-bridge.git
cd codex-bridge
```

### macOS Apple Silicon

Install Xcode and a compatible Swift toolchain.

```bash
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj -scheme CodexBridge \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

A standard source build supports local MCP. ChatGPT Secure Tunnel also requires a verified `tunnel-client`; release packages include it.

### Windows x64

Install Swift 6.3.3, Visual Studio C++ tools, Windows SDK, SQLite through vcpkg, and Inno Setup 7.1.0 for installer generation.

```powershell
pwsh -File Scripts/build-windows.ps1 `
  -VcpkgRoot 'D:\Dev\Tools\vcpkg' `
  -Installer -ISCCPath 'C:\Program Files (x86)\Inno Setup 7\ISCC.exe'
```

The script uses `swiftbuild` and writes the portable ZIP and EXE installer under `.build`.

## License and privacy

[Apache-2.0](./LICENSE) · [Third-party notices](./NOTICE) · [Dependencies](./docs/DEPENDENCIES.md) · [Privacy](./PRIVACY.md) · [Security](./SECURITY.md)

## Community

Thanks to the [LINUX DO](https://linux.do/) community.
