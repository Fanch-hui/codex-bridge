# Dependencies

The package manifests and `Package.resolved` define the Swift dependencies used to build Codex Bridge. Release packages include an SPDX software bill of materials and SHA-256 checksums.

| Component | Selection | Use |
| --- | --- | --- |
| MCP Swift SDK | 0.12.1, vendored with Windows compatibility changes | MCP protocol and transport |
| GRDB.swift | 7.11.1 | SQLite persistence |
| swift-log | 1.15.0 | Structured logging |
| swift-nio | `1a69138cb7f2e63de709c9716e0348ffd6522ac7` | Local HTTP transport; Windows loopback wakeup support |
| swift-crypto | 3.12.0 | Cryptographic hashes and primitives |
| OpenAI tunnel-client | 0.0.18, commit `274a5588414819f063d27100a4fb1096aae3830f` | Secure MCP Tunnel |
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

The official v0.0.18 full-client ZIP files were checked against GitHub Release asset digests on 2026-10-28. Build and staging scripts pin these SHA-256 values and preserve upstream LICENSE, NOTICE, third-party licenses and SPDX metadata. The macOS Universal 2 helper is derived from the two verified thin executables.

| Platform | ZIP SHA-256 | Client SHA-256 |
| --- | --- | --- |
| darwin-amd64 | `95595c6538b3f9872c1367592aede22e0d18ea7f6bdd51cd17fe0bf7e5ca8b26` | `93c019b236d834073bc9abc94b07264f8e21fabf994226f72e8d1c387c1e89d1` |
| darwin-arm64 | `ba7a0994f7dd15bc8708aa1602ecf54371a492319a641ab9c33dc00f1fd56bfe` | `5a55fd3dde505b2ee27f970dad18e6c08e04ffb9d7bc4256c507b8f312c1d6e8` |
| windows-amd64 | `8d0da1ce79532d44ccc5ed5d8bd36cdfffba37dfd287c602d69635c8bb5db2b2` | `9d0a22b7eb64fe7c5e34dfc97273ffcab6a07557855cf9e7f8869068402caf6b` |
| windows-arm64 | `b73237513d50bf7acbeb960d80d9cbb6513879292f80ec1bd04b886fac1fe1c8` | `71e8350e6dc14334b0d0ac2a637f98cdc0f0f1aac4dcd2f883354b2f9cbec70f` |
| linux-amd64 | `3c82307316acd93c88a384b62af1d81d3f4cb0efa975f9c0bfaef922866a04c4` | `55c48566e682473a602eea4951978d27acc0f2c8de2340b684a8b114feba7a83` |
| linux-arm64 | `a5f3d70efc75f5e66ab5c67c44d272aa80b2736f93f875f165140517750ec035` | `5e0c8e2cc3b49ea718a81866001625ad8ea4a19771ec3c4efaaccda0c71e715a` |

Official source and artifacts: [OpenAI tunnel-client v0.0.18](https://github.com/openai/tunnel-client/releases/tag/v0.0.18).
