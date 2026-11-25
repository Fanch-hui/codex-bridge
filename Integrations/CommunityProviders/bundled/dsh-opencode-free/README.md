# dsh-opencode-free

**English** | [繁體中文](README.zh-TW.md)

[![npm](https://img.shields.io/npm/v/dsh-opencode-free)](https://www.npmjs.com/package/dsh-opencode-free)
[![CI](https://github.com/x5427876/dsh-opencode-free/actions/workflows/ci.yml/badge.svg)](https://github.com/x5427876/dsh-opencode-free/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Use free [OpenCode Zen](https://opencode.ai/docs/providers) models in DeepSeek
Harness (DSH), without installing OpenCode or running a separate server.
Anonymous access is the default; a Zen API key is optional.

- **Works on the anonymous tier.** Zen's free tier decides by request content
  (tool declarations, an `<env>` block, the TLS cipher list), not only by headers.
  The plugin shapes anonymous requests to match; see
  [what the free tier checks](docs/free-tier-gate.md), with dated measurements.
- **No built-in model list.** The picker follows Zen's official model list: chat
  models whose declared prices are all zero. Refreshes are lazy, and a failed
  refresh keeps the last good list. Hide individual models from the detail page.
- **Native in DSH.** Models appear under **OpenCode Zen Free** with streaming,
  reasoning, tool calls, usage, and cancellation.
- **Availability checks.** The detail page shows probe results and latency. Quota
  limits and gate refusals do not remove models.
- **One release, one DSH.** Each release supports exactly one DSH version.

> [!WARNING]
> This is an unofficial plugin, not affiliated with OpenCode or DeepSeek.
> Anonymous access sends OpenCode CLI-format identity fields from this plugin,
> not the official CLI, and has no third-party access guarantee: upstream changes
> may break it without notice. Anonymous
> quota is shared by callers behind the same egress IP.
>
> The plugin runs with DSH's privileges and wraps process-wide HTTP entry points
> for the Zen inference endpoint. Read [Security and limitations](#security-and-limitations)
> and DSH's [safety notice](https://github.com/deepseek-ai/deepseek-harness/blob/master/SAFETY.md)
> before installing.

## Quick start

### Requirements

| Requirement | Version |
|---|---|
| DeepSeek Harness | `0.2.2-rc.1` (exact) |
| Node.js | `^22.19.0` or `>=24.0.0` |

Each release supports exactly one DSH version. Do not ignore peer dependency
warnings; all four runtime peers are required. For an older release, read its
[GitHub Release](https://github.com/x5427876/dsh-opencode-free/releases) or run
`npm view dsh-opencode-free@<version> peerDependencies`.

### Install

Check your DSH version, then install the pinned package:

```sh
dsh --version
dsh plugin --profile web add dsh-opencode-free@0.6.0
```

Replace `web` with your target profile. If already installed, use the update
command below instead of adding it again.

Verify the package and composed configuration:

```sh
dsh plugin --profile web list dsh-opencode-free --depth 0
dsh --profile web --dump-config
```

The package and the `opencode-free` plugin entry should each appear once.
Restart DSH (or wait for HMR), then choose a model under **OpenCode Zen Free**.

### Update or remove

```sh
dsh plugin --profile web update dsh-opencode-free
dsh plugin --profile web remove dsh-opencode-free
```

## Usage

See the [usage guide](docs/usage.md) for refresh intervals, probe results,
cache recovery, and key verification.

The model picker shows the current catalogue rather than a fixed model list.
Context sizes, image support, and reasoning levels come from each model's
published metadata. Failed refreshes preserve the cached list; without a cache,
the plugin falls back to pi-ai's bundled models.

On the plugin detail page, enable or hide models and use **Probe now** to check
availability. Reading the model list also triggers a check once per local day.
**Checks send real inference requests and consume quota**, one enabled model at
a time. Results persist across restarts.

Only catalogue withdrawal or explicit model unavailability removes a model;
gate refusals, exhausted quota, invalid keys, and network failures are
inconclusive. See the [catalogue decision rules](docs/adr/0002-catalogue-source-of-truth.md)
for refresh, removal, and cache behavior.

## Optional API key

Key priority: plugin `config.apiKey` → `OPENCODE_API_KEY` environment variable →
anonymous `public`. There is no login flow, and the plugin never switches to a
paid model automatically. A key changes authentication and quota, not the model
list; it does not guarantee access to an unavailable model.

For Desktop, configure the key in your profile's `cordis.patch.yml` rather than
relying on a shell environment:

```yaml
- id: opencode-free
  name: dsh-opencode-free
  config:
    apiKey: <your Zen key>
```

Reload DSH after changing the configuration. Keep the key and configuration
private; never include them in issue reports.

## How it works

The implementation is based on the maintainer's analysis of the OpenCode CLI
source code and request verification. It registers the
`opencode-zen-free` provider through DSH's `PiAiAdapter` and uses pi-ai transports
to call `https://opencode.ai/inference/v1` directly. Tool execution stays in DSH.

Anonymous requests carry OpenCode CLI identity headers, a time-encoded session
ID, streaming, and substantive `read` and `bash` tool declarations. The minimum
upstream admission rules are not fully verified and may change. See the
[protocol notes](docs/protocol-notes.md) for sources and evidence limits.

### What changes in model requests

These adaptations apply only to anonymous requests; keyed requests retain their
original tools and prompts.

| Adaptation | Model-visible effect |
|---|---|
| Windows shell | DSH's `pwsh` is presented as `bash`; returned calls are restored to `pwsh`. Read/shell parameter names are mapped while preserving host constraints. |
| Missing tools | Admission-only `read`/`bash` declarations are added when absent. They grant no execution capability; calls to missing tools are rejected before host dispatch. Explicit caller tool choices are preserved. |
| Compaction | Matching tool-less context-summary requests receive an OpenCode-style summary system prompt. The user turn containing the conversation is unchanged. |

Tool guidance and admission declarations add tokens; compaction replaces system
prompt tokens. Tool/history rewriting is prefix-stable for the same tool set,
but switching between anonymous and keyed access changes that prefix.
Compaction is a separate request.

## Security and limitations

- **Process-wide interception:** the plugin wraps `globalThis.fetch` and
  `node:http(s)` `request`/`get`, restricted to the HTTPS Zen inference origin
  and `/inference/v1` path or descendants. Other plugins calling that endpoint
  in the same process also receive the identity headers.
- **Profile dependency:** a `webServer` service is required for detail-page
  routes. The built-in `headless` profile does not provide it.
- **Debug privacy:** `DSH_OPENCODE_FREE_DEBUG=1` enables diagnostics. Logs name
  the credential kind (`anonymous` or `key`) and never any part of it. Upstream
  refusals contribute only the status, gate marker and error code, not their
  text. Request and session identifiers still appear, so do not publish raw logs.
- **Verification scope:** compat run results are not stored in the repository:
  they depend on environment, versions, time and the shared anonymous quota. Run
  the [compat guide](docs/compat-run.md) yourself for current evidence. The
  headless run does not verify Web, Desktop, or compaction.

## Troubleshooting

| Symptom | Next step |
|---|---|
| Plugin does not load | Check the exact DSH version, required peers, target profile, and `webServer` service. |
| `403 FreeTierError … only be used from within OpenCode` | Upstream rejected admission. This alone does not identify an IP restriction, invalid key, or retired model. Reinstalling is not a gate fix. |
| Grey “not measured” rows | The check was inconclusive, not evidence that a model is gone. Read the banner before deciding whether to probe again. |
| HTTP `200` but no reply | HTTP success is not a completed response. Try another model; preserve the model ID and sanitized error for diagnosis. |

Report bugs through [GitHub Issues](https://github.com/x5427876/dsh-opencode-free/issues)
with your plugin/DSH versions, OS, profile, and sanitized error. Never post keys,
raw logs, or conversation content.

## Development

Use the [documentation index](docs/README.md) to find task-specific guides.
Read the [engineering standards](docs/standards.md) and [known gaps](docs/standards-gap.md)
before contributing. Edit `src/`; `lib/` is generated.

```sh
pnpm install
pnpm run check  # local links, typecheck, build, offline tests, and pack
```

Default tests use fixtures and a temporary `DSH_HOME`; they do not access the
network or consume inference quota. Live checks are separate and require
explicit authorization:

- `scripts/reverify.sh` is a legacy diagnostic with outdated request assumptions,
  not a current admission or key verification test. It sends real requests and
  is available only from a clone. See the [usage guide](docs/usage.md#verify-the-configured-path).
- For actual-host verification and exit-code meanings, see the [compat run guide](docs/compat-run.md).
- For release history and agent installation procedures, see [GitHub Releases](https://github.com/x5427876/dsh-opencode-free/releases)
  and [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE).
