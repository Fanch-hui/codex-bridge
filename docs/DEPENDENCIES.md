# Dependencies

The package manifests and `Package.resolved` define the Swift dependencies used to build Codex Bridge. Release packages include an SPDX software bill of materials and SHA-256 checksums.

| Component | Selection | Use |
| --- | --- | --- |
| MCP Swift SDK | 0.12.1, vendored with Windows compatibility changes | MCP protocol and transport |
| GRDB.swift | 7.11.1 | SQLite persistence |
| swift-log | 1.15.0 | Structured logging |
| swift-nio | `1a69138cb7f2e63de709c9716e0348ffd6522ac7` | Local HTTP transport; Windows loopback wakeup support |
| swift-crypto | 3.12.0 | Cryptographic hashes and primitives |
| OpenAI tunnel-client | 0.0.17, commit `a248b7f725fc989c1eb26680cf4351ee33421f61` | Secure MCP Tunnel |
| WebView2 SDK | 1.0.4191.47 | Windows embedded browser loader |

macOS uses WKWebView and XPC. Windows uses WebView2 and named pipes. Both platforms load the shared local `BridgeDesktopUI` resources.

Codex, OpenCode, DeepSeek Harness, and Antigravity run as separate agent processes. Available capabilities are determined by each installed agent's entrypoint and runtime probe. DeepSeek Harness uses a Node runtime and ACP configuration managed by the Bridge adapter.

## Packaging

- Swift runtime files must match the selected Swift toolchain and target architecture.
- Windows packages include matching SQLite, WebView2 loader, and app-local VC runtime files.
- Tunnel helper binaries are checked for the expected architecture and SHA-256 before staging.
- macOS signs embedded executable components before signing the app, then records the final helper digest.
- Application data and browser profiles remain outside the installation payload.

See [NOTICE](../NOTICE) and the bundled dependency licenses for third-party attribution.

## Tunnel helper supply pin

The official v0.0.17 full-client ZIP files were checked against GitHub Release asset digests on 2026-10-22. Build and staging scripts pin these SHA-256 values and preserve upstream LICENSE, NOTICE, third-party licenses and SPDX metadata. The macOS Universal 2 helper is derived from the two verified thin executables.

| Platform | ZIP SHA-256 | Client SHA-256 |
| --- | --- | --- |
| darwin-amd64 | `1d54cc57e0a624dc733d402f7d36585f2135a23ddc32c4cb52a7253c7d8d94a0` | `87849b2f297b3ca20ec69a61d6a50a0edd6d98d7e7ebb1b832bdcaf4a184cb9d` |
| darwin-arm64 | `df03ad0ba9c95c22951bab6833df289469f15b9a3fa0397d95e3d568d1ff6c1f` | `d8f165d8175fa9f813a113b6ef434aed25a384f765a69b3709228704e5347474` |
| windows-amd64 | `b89074637596262067061308cf174959561a1a8bcffe2db956650dad7303052b` | `61a770c759c386845f830a106f7e6d0d3f854b932259744a88b4013c282e64ec` |
| windows-arm64 | `925c8298e46e088413bb02c81d36775f2e818970231bc2ecc215fcb0f0382bf7` | `2986f8ea93ead7462d0babfecd858bf50dd04dff750fbab938e182ec6544f590` |
| linux-amd64 | `bd6a57c6c0511644267cafadd13ffdb53ece0d753e0b88857f957e78a8fbc793` | `e163ff89cfc3c8bd9d196fe3fd622ba39d009af9935e38432790f39eb9b6db01` |
| linux-arm64 | `f5060d0b63663268aab3ca310cb6110fa14867981db2b0657f679d8836a2daa0` | `683afd34c71fca51670cf3d79d47abd5c717ecb3a52d721f3449c3ed41f36c60` |

Official source and artifacts: [OpenAI tunnel-client v0.0.17](https://github.com/openai/tunnel-client/releases/tag/v0.0.17).
