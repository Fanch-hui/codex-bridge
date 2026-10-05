# Connecting Pi and Qoder

Pi and Qoder use local runtimes and native sign-in state. Click **One-click setup** in Connections to reuse an existing installation or prepare the official CLI, Node/npm, and Qoder SDK, then follow the sign-in instructions. Select the Qoder region first. See the [setup guide (Chinese)](./AGENT_SETUP_GUIDE.md) for installation locations and retries.

The commands below are for installations you manage yourself.

## Pi

```sh
npm install -g @earendil-works/pi-coding-agent@0.87.1
pi
```

Run `/login` in Pi to sign in to your model provider. In Bridge, open Connections, click **Scan Agents**, and connect Pi. The model catalog comes from Pi's available models. An empty catalog requires provider configuration or sign-in in Pi first.

## Qoder CN

The CLI and SDK must belong to the same region and use matching versions. This pair has been checked against the official contracts:

```sh
npm install -g @qodercn-ai/qoderclicn@1.1.64 @qodercn-ai/qodercn-agent-sdk@1.0.50
qoderclicn login
```

Select the China region on the Qoder connection card, scan local installations, select the active installation, and connect. The international region uses the separate `@qoder-ai/qodercli` and `@qoder-ai/qoder-agent-sdk` packages. Select that region explicitly on the same card. Model defaults and runtime settings are stored separately for each region.

Changing regions affects defaults for new tasks. Continuing an existing session uses its original region and installation binding.

In **Settings → Agent Models and Permissions → Qoder Execution Permissions**, choose **Request approval**, **Approve for me**, or **Allow full access** for the selected region. Qoder decides whether to allow each operation in the second mode; the third skips Qoder's per-operation permission prompts. The user-selected task permission still applies: Read Only prohibits writes and network tools; Full includes writes and network tools. The latter two modes require the project directory to be trusted by Qoder. Permission settings are stored separately for each region.

## Installation discovery and runtime paths

Bridge scans and saves installations on first initialization. An upgrade that adds an agent fills in missing catalog entries. After installing or moving an agent, click **Scan Agents**. Discovery covers PATH, user installation locations, and common Node package manager directories.

Leave Qoder's Node path and SDK directory blank to resolve them from the selected CLI. For custom installations, use absolute paths. The SDK directory must contain the matching region's SDK `package.json`. Windows npm wrappers resolve to the official package's JavaScript entry, which runs with Node.

Bridge validates the CLI, Node, SDK, and bundled host resources. Changed files require a new probe. If a version, region, or digest does not match, correct the selected installation and SDK, then reconnect.

## Common messages

- **Installation not found:** verify that the native command reports its version, then scan. Custom locations can be registered manually.
- **Sign-in required or expired:** sign in using the selected region's CLI, then reconnect.
- **SDK unavailable or version mismatch:** check the SDK region, required CLI version, and SDK directory.
- **Model unavailable:** check the model catalog and provider configuration in the native agent first.

MCP servers are configured separately for Pi, Qoder CN, and Qoder international. The user chooses Read Only or Full; ChatGPT/Qwen tasks inherit the default selected in Workbench, and AI clients do not select permissions. Pi/Qoder enforce Read Only through controlled application tools, which is not operating-system isolation. Native tool rules and local approval decisions also apply.

When continuing or restarting a Pi/Qoder task in the workbench, enter names from the project's Skills list in the Skills field, separated by commas. Leave it empty to retain the session's selection. MCP submissions accept `skill_names`; the singular `skill_name` field remains supported.
