# DeepSeek Harness Connection Guide

This guide describes the DeepSeek Harness (DSH) setup supported by Bridge. The [Chinese guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) contains the most detailed troubleshooting and task examples.

The provider ID is:

```text
deepseek-harness
```

Omitting `provider_id` selects Codex, not DSH.

## 1. Compatibility boundary and reference revision

Bridge does not use exact DSH, agent, pnpm, or ACP SDK package versions as an allowlist. It validates the entry layout and package identity, the source manifest and dependency-lock artifact identities, the real Node interpreter identity, the ACP handshake and wire protocol, and the external profile structure. Re-run Probe after an upgrade or replacement. Bridge does not read Git metadata or treat a tag as proof of compatibility.

This guide was checked against the official `dsh-v0.1.5-rc.2` revision. That tag is a reference point for this review, not a required checkout or a Bridge version allowlist. Other official revisions can continue to work when artifact validation, the Node minimum, ACP protocol 1, and Probe pass.

| Component | Compatibility boundary |
| --- | --- |
| DSH source and package version | Official source; follows upstream, with no exact Bridge version pin |
| ACP wire protocol | `1` |
| Node | `^22.19.0` or `>=24.0.0` |
| pnpm, agent, and ACP SDK | Use the versions declared and installed by the checked-out source; Bridge does not impose separate exact pins |

Node 22.18.x and Node 23 are not supported. Node 22.19.0+ within 22.x and Node 24+ are supported.

The modern entry supports grouped model choices, selected-model reasoning options, reasoning text, and context usage updates. Standard ACP completion checks the stop reason, final answer, and tool states; the older execution-evidence extension is still validated when present.

Modern DSH sessions support cross-process continuation and the MCP servers configured in the App. Native real-time steer and transcript replay remain unavailable in upstream ACP; displayed history comes from Bridge task records.

## 2. Clone and build the correct entry point

Use the official [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) repository. You may use the current official branch or another official revision. To reproduce this guide's reference point, optionally checkout `dsh-v0.1.5-rc.2`; Bridge does not require that tag:

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
cd deepseek-harness

# Optional: reproduce this guide's reference revision
git fetch --tags origin
git checkout --detach dsh-v0.1.5-rc.2
```

Do not use a third-party repackaged script, a global `dsh` command, or source TypeScript as Bridge's ACP entry.

## 3. Prepare Node and pnpm

Check the versions available to the service environment:

```bash
node --version
pnpm --version
```

Use a Node runtime in the supported range above. Use the package-manager version declared by the checked-out DSH source or a compatible version; the reference source declares `pnpm@11.7.0`, but Bridge does not enforce that exact value. An interactive-shell alias is not a reliable service runtime.

The current official source builds the ACP entry with the root commands below. Register this absolute path in Bridge:

```bash
pnpm install
pnpm run build
test -f apps/cli/lib/bin.js
```

```text
<dsh-source>/apps/cli/lib/bin.js
```

The older ACP Demo entry remains compatible for existing registrations:

```text
<dsh-source>/packages/examples/acp-demo/lib/bin.js
```

The modern entry runs as `--profile acp --patch <Bridge private runtime configuration>`. The legacy ACP Demo entry continues to use `--config <Bridge private runtime copy>/cordis.yml`; Bridge selects the launch form from the entry layout.

Bridge executes the built entry directly with Node and does not require a running terminal or browser UI. Keep the complete source tree. Moving `bin.js` by itself removes the manifest, dependency lock, modules, and source-root identity that Bridge validates.

The entry point commonly uses `#!/usr/bin/env node`. Bridge resolves the real Node executable rather than treating `/usr/bin/env` as Node. A Node installation that exists only after interactive `nvm`/`asdf` shell initialization may be unavailable to the macOS LaunchAgent; the app's Probe result is authoritative.

## 4. Create an external profile

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

For the modern `apps/cli/lib/bin.js` entry, Bridge reads and validates the existing external `cordis.yml`, then writes a private per-run `acp.patch.yml` and launches with `--profile acp --patch`. The user's original `cordis.yml` is not rewritten. The legacy ACP Demo entry continues to use a private `cordis.yml` with `--config`.

Keep the packaged `dsh-user-approval` plugin at `policy: ask`. Bridge uses it to surface DSH `session/request_permission` calls in Workbench. Removing the approval plugin or changing the sandbox to `danger-full-access` is not a supported user configuration.

## 5. Configure `.env`

Create a DeepSeek API key at [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys). Store the real key only in the external profile's `.env`; never paste it into Bridge, ChatGPT, source control, screenshots, or issue reports.

From the Bridge repository:

```bash
cp Examples/DeepSeekHarnessProfile/.env.example \
  /path/to/dsh-profile/.env
chmod 600 /path/to/dsh-profile/.env
```

The current variables are:

```dotenv
DEEPSEEK_API_KEY=<fill locally>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

`DEEPSEEK_BASE_URL` is the Chat Completions base URL. Do not include `/chat/completions`; DSH appends it.

`DEEPSEEK_SEARCH_BASE_URL` is independent. Do not include `/messages`; DSH appends it. The endpoint must accept Anthropic Messages-compatible requests and support the native `web_search_20250305` server tool. A working main model or a generic `/messages` endpoint does not prove that Web Search works.

The packaged profile currently uses `DEEPSEEK_API_KEY` for both paths. If a custom gateway needs separate credentials, verify its support before changing the validated profile; Bridge will not read or translate credentials.

Bridge launches DSH with the profile directory as its working directory, so Harness loads the adjacent `.env` itself. Bridge does not open, persist, summarize, log, or return its contents.

## 6. Connect in the app

1. Open `Connections → Local Agent Engine Connections`.
2. Enter the Base URL and API key under DeepSeek Harness.
3. Click the one-click connection button and wait for discovery, configuration, and Probe.
4. Check availability; a successful Probe enables the agent.

macOS and Windows share this flow. The API key is stored in the system credential store and passed to Harness through its process environment. The external profile and `.env` instructions above apply to advanced manual registration, which accepts the ACP entry point and `cordis.yml` paths.

Probe validates the local installation, protocol, and basic ACP session. API authentication and model execution are verified when running a task.

## 7. Refresh models and defaults

1. Select the task project in Workbench.
2. Open the DeepSeek Harness execution defaults in Settings.
3. Select the installation if more than one exists.
4. Refresh the model list.
5. Select exact model IDs returned by ACP `session/new.configOptions`. Effort values come from the validated DSH Profile rather than per-model ACP advertising; the bundled thinking-enabled Profile supports `off`, `low`, `high`, and `max` with default `max`.

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

Only when the user explicitly requests overrides should the client add `model_override`, exact model/Profile-supported effort values, or `permission_mode_override`. Omit Codex Supervisor fields. For continuation, pass the `provider_session_id` of a completed task as `thread_id` when `lifecycle.session_continue` is available. The project and installation must match, and persistent session data must still exist. `skill_name` is valid only when the user explicitly selects a discovered Bridge Skill.

Remote submissions normally enter `awaiting_local_approval`. Review project, provider, access mode, network intent, and prompt in Workbench before approving the start. Automatic remote-start approval is disabled by default and never approves later DSH permission requests or Direct operations.

When DSH requests a runtime tool, the persisted task state uses `waiting_for_codex_approval` for compatibility even though the provider remains DSH. In Workbench, inspect the approval card and choose one-shot allow or deny. There is currently no session-wide allow choice for DSH.

Follow `get_task.wait_policy` and read terminal results from the same `get_task` snapshot: `result_summary`, `failure_code`, `changed_files`, activity, model/effort, and provider bindings. Terminal `next_action=read_final_report` is a hint string, not another MCP tool.

Queued steer sends a second prompt after the current prompt finishes. DSH also supports interrupt-current-then-continue for the active session. Neither is Codex in-flight steer.

## 10. Availability and troubleshooting

| Symptom | Check first |
| --- | --- |
| Invalid artifact | Use the official built `apps/cli/lib/bin.js`, or the compatible `packages/examples/acp-demo/lib/bin.js`; retain the full source tree |
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
- [Detailed Chinese DSH guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [Detailed user guide](./USER_GUIDE.md)

## MCP configuration and continuation

Use the DSH MCP section on Connections to manage stdio and Streamable HTTP servers. Stdio commands require absolute paths; enter arguments one per line. HTTP servers are attached only to tasks with network access enabled. Environment and header values use the system credential store and are never returned to the editor. Leave a saved value blank to retain it, or remove its row to delete it. Changes apply to the next task or continuation.

Choose Continue conversation on an ended task to retain its context after a Service restart. Sessions cleared by older temporary-runtime versions cannot be recovered.
