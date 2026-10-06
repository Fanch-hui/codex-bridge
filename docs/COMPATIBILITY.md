# Compatibility Matrix

Compatibility is determined by the installed runtime, protocol handshake and observed capabilities. Discovery, protocol tests, authenticated execution and desktop UI acceptance provide separate evidence.

| Component | Supported baseline | Compatibility checks | Notes |
|---|---|---|---|
| macOS | 14 or later; arm64 and x86_64 | separate native CI runners and architecture-specific App packages | Each package contains a matching App, Service and Tunnel helper. |
| Windows | x64 and ARM64 | native `windows-latest` and `windows-11-arm` runners; portable and EXE lifecycle checks | WebView2 Evergreen Runtime is required. |
| Linux | Ubuntu 24.04 LTS; x64 and ARM64 | native CI runners; `.deb` installation, IPC and removal checks | GTK 3, WebKitGTK 4.1 and Secret Service provide desktop integration. |
| Swift / Xcode | Swift 6; complete Xcode for macOS; Swift 6.3.3 on Windows/Linux | exact dependency pins and unchanged `Package.resolved` | Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` for another Xcode installation. Command Line Tools alone are insufficient for the App build. |
| Codex CLI | installed `app-server` protocol | initialization, dynamic model catalog, framing and task-control checks | [Version-specific protocol evidence](CODEX_PROTOCOL_COMPATIBILITY.md) is a historical baseline, not a current version allowlist. |
| OpenCode | ACP v1; version >= `1.18.20` | agent identity, ACP handshake, dynamic models, permission events and continuation | No fixed upper version bound. Installed separately; a continued session must match the project and installation binding. |
| DeepSeek Harness — ACP | compatible official CLI/npm entry, Desktop-bundled CLI, or legacy ACP demo | artifact/runtime/profile validation, ACP v1 handshake and current session configuration | Legacy `0.1.1-rc.2` demo support remains. Modern entries use a separate Bridge profile; continuation depends on native resume support and persistent session binding. [ACP guide](DEEPSEEK_HARNESS_CONNECTION_GUIDE.md). |
| DeepSeek Harness — native desktop | official Desktop Host with paired Bridge Connector; macOS and Windows x64 | signed local protocol, profile identity, native session/model services and runtime-resource digests | Reuses Desktop account, tools and sessions. Complete-permission text tasks only. Linux and Windows ARM64 use ACP. [Native desktop guide](DSH_NATIVE_DESKTOP_GUIDE.md). |
| Antigravity CLI | required options advertised by the installed CLI's `--help` | CLI version display, stream-json, native permissions, model catalog and continuation | Model IDs include reasoning strength; independent effort is unsupported. Headless tool approvals remain an adapter boundary. |
| Pi | native JSONL RPC plus Bridge extension contract | initialization, current provider/model catalog, extension handshake, task controls and native history | Exact model keys take priority. Azure provider aliases apply only to the same model ID in the current catalog; native authentication migration remains user-owned. [Pi guide](PI_QODER_CONNECTION_GUIDE.md). |
| Qoder | native Node SDK host and installed regional CLI | SDK methods, native tools/capabilities, models and session binding | CN and international preferences/login/session bindings remain separate. SDK and CLI patch versions may differ. [Qoder guide](PI_QODER_CONNECTION_GUIDE.md). |
| Swift MCP SDK | 0.12.1 | exact pin and local protocol checks | BridgeMCP implements the production HTTP listener. |
| MCP Inspector | 2.1.0 on Node 22.19+ | development-only acceptance script | Available in the full development tree; never bundled. |
| OpenAI tunnel-client | 0.0.10, commit `105e17a79a36e4e5c897fd698ed2b8dbf935b144` | pinned archives, architecture/digest checks, loopback ownership and helper lifecycle | Platform Tunnels is the support source of truth. Unsigned preview packages ad-hoc sign the selected helper slice. |
| ChatGPT custom MCP plugin | current Secure MCP Tunnel client behavior | local helper, admission and MCP contract checks; account connection requires user acceptance | Create from Plugins → Add → Create custom MCP server and select Tunnel. The Runtime Key stays in Bridge. |

## Execution and capability boundaries

- Codex `model/list` supplies discovery and capability hints. Saved or explicit model/effort selections are not rejected merely because the current catalog omits them; the native runtime confirms availability. Bridge never silently substitutes another selection.
- Other Agent model and effort selections follow the current provider catalog. Refresh failures preserve existing preferences and report the failure; no model suffix or cross-provider alias is guessed. Pi's same-model Azure compatibility mapping is the explicit exception described above.
- OpenCode Read Only runs use a unique primary Agent with final native tool rules allowing read, glob, grep and question while denying other tools. Full tasks retain native permissions. This is tool enforcement, not an OS network sandbox; prompts and continuation are sent as literal text.
- DSH ACP model/effort capabilities come from the current session configuration and validated profile. Native desktop reads the paired Host catalog and persists Bridge model/effort selections to Desktop defaults with readback confirmation.
- Antigravity forwards the exact catalog model ID and rejects nonempty independent effort before launch. Antigravity and both DSH modes report Read Only as unsupported rather than upgrading it to Full.
- Pi and Qoder task permissions use their adapter/native tool policies. Provider capability declarations determine whether a Read Only request can start; unavailable capabilities produce an explicit error.
- Session continuation validates installation, project and native session identity. DSH tasks also retain their submitted connection mode, profile and input request ID even when defaults change.
- If the Service loses the original active Codex event stream, it does not start a replacement turn and pretend to have resumed the original. Recovery reconciles persisted turn facts and preserves the task's locks until ownership/termination is resolved.
- Supervisor is unavailable on all platforms; enabling it is rejected. Codex approvals use the supported local desktop channel, and unknown native approval requests are refused.
- Tunnel readiness requires exact helper-process ownership of the loopback health port, strict `/readyz`, and a fresh successful control-plane poll metric.
- tunnel-client v0.0.10 `doctor` has a documented false failure for an intentionally no-OAuth MCP endpoint returning PRMD 404. Bridge accepts only that exact structured single-failure result; any additional failed check remains fatal.

Public source excludes development tests, fixtures, prototypes and generated schemas. Commands that use those paths require the full development tree. Runtime resources can be checked from the public checkout with `node Scripts/verify-agent-runtime-resources.mjs`; authenticated tasks and desktop navigation require direct user acceptance.
