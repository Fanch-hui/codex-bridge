# DeepSeek Harness Connection Guide

This guide describes the DeepSeek Harness (DSH) setup supported by Bridge. The [Chinese guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) contains the most detailed troubleshooting and task examples.

The shortest path is: build DSH from the official repository, open `Connections → Local Agent Engine Connections → DeepSeek Harness`, enter the Base URL and API key, connect it, then refresh the model list in Settings. macOS and Windows use the same flow. The key is stored in the system credential store and injected only into the Harness process environment. Use an external profile and `.env` when you need an independent search endpoint, a fixed local profile, or manual registration.

The provider ID is:

```text
deepseek-harness
```

Omitting `provider_id` selects Codex, not DSH.

## 1. Compatibility boundary

Bridge does not use exact DSH, agent, pnpm, or ACP SDK package versions as an allowlist. It validates the entry layout and package identity, the source manifest and dependency-lock artifact identities, the real Node interpreter identity, the ACP handshake and wire protocol, and the external profile structure. Re-run Probe after an upgrade or replacement. Bridge does not read Git metadata or treat a tag as proof of compatibility.

Use the current source or an official revision from the [DeepSeek Harness repository](https://github.com/deepseek-ai/deepseek-harness). Bridge does not require a fixed tag. A revision is usable when its entry point, artifacts, Node runtime, ACP protocol 1, and Probe satisfy the checks below.

| Component | Compatibility boundary |
| --- | --- |
| DSH source and package version | Official source; follows upstream, with no exact Bridge version pin |
| ACP wire protocol | `1` |
| Node | `^22.19.0` or `>=24.0.0` |
| pnpm, agent, and ACP SDK | Use the versions declared and installed by the checked-out source; Bridge does not impose separate exact pins |

Node 22.18.x and Node 23 are not supported. Node 22.19.0+ within 22.x and Node 24+ are supported.

The modern entry supports grouped model choices, selected-model reasoning options, reasoning text, and context usage updates. Standard ACP completion checks the stop reason, final answer, and tool states; the older execution-evidence extension is still validated when present.

Modern DSH supports cross-process continuation when ACP initialization advertises `resume` and Bridge persistence is available. It also receives the MCP servers configured in the App. Native real-time steer and transcript replay remain unavailable in upstream ACP; displayed history comes from Bridge task records.

## 2. Clone the official source

Use the official [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) repository and its current official branch, or another official revision:

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
cd deepseek-harness
```

Do not use a third-party repackaged script, a global `dsh` command, or source TypeScript as Bridge's ACP entry.

## 3. Prepare Node, pnpm, and the ACP entry

Check the versions available to your terminal and Bridge Service:

```bash
node --version
pnpm --version
```

Use a Node runtime in the supported range above. Use the package-manager version declared by the checked-out DSH source or a compatible version. Install Node from the [official Node.js download page](https://nodejs.org/en/download/) and pnpm from the [official pnpm installation guide](https://pnpm.io/installation). An interactive-shell alias is not a reliable service runtime; reopen the terminal and check both versions after installation.

The current official source builds the modern ACP entry with the root commands below. Register this absolute path in Bridge:

```bash
pnpm install
pnpm run build
```

macOS, Linux, or Git Bash:

```bash
test -f apps/cli/lib/bin.js
```

Windows PowerShell:

```powershell
Test-Path .\apps\cli\lib\bin.js
```

```text
<dsh-source>/apps/cli/lib/bin.js
```

Bridge runs this entry as `--profile acp --patch <Bridge private runtime configuration>`. It creates a private patch for each run and leaves your original profile unchanged.

Bridge executes the built entry directly with Node and does not require a running terminal or browser UI. Keep the complete source tree. Moving `bin.js` by itself removes the manifest, dependency lock, modules, and source-root identity that Bridge validates.

The entry point commonly uses `#!/usr/bin/env node`. Bridge resolves the real Node executable rather than treating `/usr/bin/env` as Node. A Node installation that exists only after interactive `nvm`/`asdf` shell initialization may be unavailable to the macOS LaunchAgent; the app's Probe result is authoritative.

## Recommended path: connect in the app

Most users do not need an external profile or `.env` file. After building DSH, configure the main model connection in the app:

1. Sign in to [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys), create a new API key, and copy it when it is shown.
2. Open `Connections → Local Agent Engine Connections` and find DeepSeek Harness.
3. Enter the main model Base URL (default `https://api.deepseek.com`) and the API key in the connection row.
4. Click `Connect` and wait for discovery, configuration, and Probe. A successful Probe enables the installation.
5. Open Settings, refresh the model catalog, and select a model returned for your account.

Bridge stores the key in macOS Keychain or Windows Credential Manager, clears the field after submission, and injects it only when starting the DSH child process. Read the advanced sections below only for manual registration, an independent Web Search endpoint, or a fixed local profile.

## 4. Advanced optional: external profile

This section is only for manual registration, a fixed profile, or a separate search endpoint. Users following the recommended one-click flow can skip this section and the next one.

Runtime validation requires the profile to be outside the DSH source tree. For credential isolation and to prevent accidental Agent/Git access, also keep it outside task projects and the Bridge repository:

- **Required:** the DSH source tree;
- **Recommended:** every task project;
- **Recommended:** the Codex Bridge repository.

Use this layout:

```text
<dsh-profile>/
├── cordis.yml
└── .env
```

When creating a new profile, you may copy the complete `cordis.yml` template shipped with Bridge. Keep an existing external `cordis.yml` when upgrading; it remains Bridge's source for model and effort configuration. Final compatibility is determined by profile-structure validation and Probe.

From a Bridge source checkout:

```bash
mkdir -p /path/to/dsh-profile
cp Packages/BridgeCore/Sources/BridgeDeepSeekHarnessACP/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

From the installed app:

```bash
mkdir -p /path/to/dsh-profile
cp /Applications/CodexBridge.app/Contents/Resources/BridgeCore_BridgeDeepSeekHarnessACP.bundle/Contents/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

Do not rebuild or trim the template from an upstream generic example. It contains the Bridge profile structure used for model and effort configuration. Model and effort values are the expected configurable parts; compatible trailing composition can also pass normalized structure validation. Re-Probe every change because incompatible edits cause `templateMismatch` or `needs_review`.

For `apps/cli/lib/bin.js`, Bridge reads and validates the external `cordis.yml`, then writes a private per-run `acp.patch.yml` and launches with `--profile acp --patch`. The user's original `cordis.yml` is not rewritten.

Keep the packaged `dsh-user-approval` plugin at `policy: ask`. Bridge uses it to surface DSH `session/request_permission` calls in Workbench. Removing the approval plugin or changing the sandbox to `danger-full-access` is not a supported user configuration.

## 5. Advanced optional: `.env` and independent endpoints

This section is only for the manual profile in Section 4 or an independent Web Search endpoint. The recommended one-click flow stores the API key directly from the App connection row and does not require a hand-created `.env` file.

Create a DeepSeek API key at [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys). Sign in, open API Keys, create a new key, and copy it when it is shown; button names can change with the platform. This is a DeepSeek API credential, separate from a ChatGPT login, OpenAI Tunnel Runtime Key, or OpenAI API key. Store the real key only in Bridge's password field or the external profile's `.env`; never paste it into a project `.env`, ChatGPT, source control, screenshots, or issue reports.

The current variables are; fill the key only on your machine:

```dotenv
DEEPSEEK_API_KEY=<fill locally>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

`DEEPSEEK_BASE_URL` is the Chat Completions base URL. Do not include `/chat/completions`; DSH appends it.

`DEEPSEEK_SEARCH_BASE_URL` is independent. Do not include `/messages`; DSH appends it. The endpoint must accept Anthropic Messages-compatible requests and support the native `web_search_20250305` server tool. A working main model or a generic `/messages` endpoint does not prove that Web Search works.

The packaged profile currently uses `DEEPSEEK_API_KEY` for both paths. If a custom gateway needs separate credentials, verify its support before changing the validated profile; Bridge will not read or translate credentials.

The modern DSH process runs from a private temporary runtime directory created for that run, not from the profile directory. Bridge starts Node with a preload script that reads `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, and `DEEPSEEK_SEARCH_BASE_URL` from the `.env` beside the registered `cordis.yml` only when the system credential store or existing process environment does not already provide the same value. Bridge does not use the profile directory as DSH's working directory, and does not persist, summarize, log, or return `.env` contents.

With manual registration, keep the key in the external profile's `.env`; the App field can remain empty.

## 6. Connection status and manual registration

The recommended path above completes one-click connection in the App. The connection row shows the installation status; use `Retry` after correcting an error.

If DSH is not discovered, expand `Advanced: Register an existing installation`, choose `<dsh-source>/apps/cli/lib/bin.js`, and then choose the external `<dsh-profile>/cordis.yml`. Probe it and enable the installation from its details. This does not move or delete the DSH source tree.

macOS and Windows share this flow. The external profile and `.env` instructions above apply to advanced manual registration and to an independent search endpoint.

Probe validates the local installation, protocol, and basic ACP session. Model refresh also reads `/models` from the main Base URL; API quota, model execution, and Web Search are verified when running a task.

## 7. Refresh models and defaults

1. Select the task project in Workbench.
2. Open the DeepSeek Harness execution defaults in Settings.
3. Select the installation if more than one exists.
4. Refresh the model list.
5. Select an exact model ID returned by the current provider. Effort values come from the selected model's current ACP session `thought_level`/`reasoning_effort` options; the bundled profile's `off`, `low`, `high`, and `max` values are only initial examples, and the current ACP session is authoritative.

For the modern entry, Bridge obtains the catalog in two stages:

```text
GET <DEEPSEEK_BASE_URL>/models
        ↓
ACP session/new → configOptions
```

The main endpoint therefore needs a Bearer-authenticated OpenAI-compatible `/models` response and Chat Completions support. A typical response contains `{"data":[{"id":"..."}]}`. Bridge uses provider-returned IDs and does not treat the bundled `deepseek-v4-pro` example as proof that your account can use that model.

Do not copy model IDs or effort values from Codex, OpenCode, or Antigravity. Without an explicit user override, Bridge preserves the provider/profile current value or a saved default that remains valid.

ChatGPT/Qwen permission defaults come from `Workbench → Read Only / Write`. Project hard policy still outranks the Workbench setting and every task override.

## 8. Configure permissions for normal use

DSH has two separate approval stages:

1. Remote task start: approve the `awaiting_local_approval` task in Workbench, unless automatic remote-start approval is intentionally enabled.
2. Runtime tool permission: when the task enters `waiting_for_codex_approval`, open `Workbench → Pending Local Approval`, inspect the command, scope, and paths, then select one-shot allow or deny.

Current DSH ACP accepts only `allow_once` and `reject_once`. `full-access`, `auto-review`, `network_access=true`, and automatic task-start approval do not bypass runtime DSH permissions. One task may therefore ask more than once.

For read-only analysis:

1. Allow project reads and deny project writes.
2. Select `Read Only` in Workbench.
3. Send `network_access=false` unless the task explicitly needs network access.
4. Approve the start and handle any runtime command/tool request one at a time.

For code changes:

1. Allow project reads and writes.
2. Select `Write` in Workbench.
3. Ensure no other write task is active for the same project.
4. Approve the start, then resolve each DSH runtime permission request.

For Web Search:

1. Configure the adjacent `.env` and a search endpoint that supports `web_search_20250305`.
2. Set the project network intent consistently and send `network_access=true`.
3. Approve the start and any runtime Web-tool permission.

The search endpoint defaults to the main Base URL and key. If it is different, set `DEEPSEEK_SEARCH_BASE_URL` in the external profile's `.env`; the App Base URL field configures the main model endpoint only. Do not include `/messages`; DSH appends it. The endpoint must accept Anthropic Messages-compatible requests and the native `web_search_20250305` server tool.

The project network selector is not a packet-level firewall for external providers. The current DSH launcher does not rewrite its profile from `network_access`; actual model and Web access remain governed by DSH's profile, endpoints, and native tools.

## 9. Submit a task

Call `list_projects` and `list_agents` first. Confirm the installation is available, enabled, and accepts task submissions.

With the correct Workbench project and permission selected, the minimal task is:

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "Inspect the current project and summarize its build problem.",
  "network_access": false
}
```

Web Search, URL fetch, and external APIs require explicit network intent:

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "Verify the dependency against official sources and cite them.",
  "network_access": true
}
```

Only when the user explicitly requests overrides should the client add `model_override`, the exact effort returned by the selected model's current ACP session, or `permission_mode_override`. For continuation, pass the `provider_session_id` of a completed task as `thread_id` when `lifecycle.session_continue` is available. The project and installation must match, and persistent session data must still exist. `skill_name` is valid only when the user explicitly selects a discovered Bridge Skill.

Remote submissions normally enter `awaiting_local_approval`. Review project, provider, access mode, network intent, and prompt in Workbench before approving the start. Automatic remote-start approval is disabled by default and never approves later DSH permission requests or Direct operations.

When DSH requests a runtime tool, the persisted task state uses `waiting_for_codex_approval` for compatibility even though the provider remains DSH. In Workbench, inspect the approval card and choose one-shot allow or deny. There is currently no session-wide allow choice for DSH.

Follow `get_task.wait_policy` and read terminal results from the same `get_task` snapshot: `result_summary`, `failure_code`, `changed_files`, activity, model/effort, and provider bindings. Terminal `next_action=read_final_report` is a hint string, not another MCP tool.

Queued steer sends a second prompt after the current prompt finishes. DSH also supports interrupt-current-then-continue for the active session. Neither is Codex in-flight steer.

## 10. MCP configuration and continuation

Use the DSH MCP section on Connections to manage stdio and Streamable HTTP servers. Stdio commands require absolute paths; enter arguments one per line. HTTP servers are attached only to tasks with network access enabled. Environment and header values use the system credential store and are never returned to the editor. Leave a saved value blank to retain it, or remove its row to delete it. Changes apply to the next task or continuation.

Choose Continue conversation on an ended task to retain its context after a Service restart. Resume requires the same project and installation, an ACP `resume` capability, and persistent session data. Sessions cleared by older temporary-runtime versions cannot be recovered.

## 11. Availability and troubleshooting

| Symptom | Check first |
| --- | --- |
| Invalid artifact | Use the official built `apps/cli/lib/bin.js`; retain the full source tree |
| Unsupported Node | Use Node 22.19.0+ within 22.x, or Node 24+; do not use Node 23 |
| Node not found by the app | Ensure the LaunchAgent can resolve the real interpreter, not only an interactive shell alias |
| Manifest/lock missing | Do not copy `bin.js` away from its source tree |
| Profile location rejected | Runtime validation requires moving `cordis.yml` and `.env` outside the DSH source; keeping them outside task projects is also recommended |
| `templateMismatch` | Preserve the existing external `cordis.yml`; merge only the required structure from the current Bridge template, then Probe again |
| `needs_review` | Verify expected entry point, manifest, lock, Node, adapter, or profile replacement, then accept and Probe |
| Probe works but API auth fails | Confirm `.env` is adjacent to the registered config, the key is valid, and the main base URL is correct |
| Main model works but search fails | Check the independent search base URL, key acceptance, and `web_search_20250305` support |
| Model list is empty | Select the project and installation, refresh ACP config options, and use exact provider values |
| Write denied | Check Workbench mode, project hard policy, and the per-project write gate |
| Network denied | Set explicit `network_access=true`; verify the adjacent `.env`, endpoint support, and current DSH runtime approval. The project selector is not an external-provider packet firewall |
| Start was approved but the task still waits | Open Workbench pending approvals, inspect the DSH tool request, and choose one-shot allow or deny |
| Runtime approval repeats | DSH supports only `allow_once` / `reject_once`; `full-access` does not bypass it |
| Automatic task start still shows approvals | It skips only `awaiting_local_approval`, not DSH `session/request_permission` |

Do not paste `.env` or raw authentication responses into support reports. Probe success is not end-to-end acceptance: validate the real model, Web Search, read-only task, write task, and permission flow with your own account and a safe test project.

## References

- [DeepSeek Harness official repository](https://github.com/deepseek-ai/deepseek-harness)
- [DeepSeek API documentation](https://api-docs.deepseek.com/)
- [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
- [Node.js official download page](https://nodejs.org/en/download/)
- [pnpm installation guide](https://pnpm.io/installation)
- [Detailed Chinese DSH guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [Detailed user guide](./USER_GUIDE.md)
- [ChatGPT Developer Mode and Secure Tunnel guide](./CHATGPT_DEVELOPER_MODE.md)
