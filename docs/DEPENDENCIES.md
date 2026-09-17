# Dependencies

The package manifests and `Package.resolved` define the Swift dependencies used to build Codex Bridge. Release packages include an SPDX software bill of materials and SHA-256 checksums.

| Component | Selection | Use |
| --- | --- | --- |
| MCP Swift SDK | 0.12.1, vendored with Windows compatibility changes | MCP protocol and transport |
| GRDB.swift | 7.11.1 | SQLite persistence |
| swift-log | 1.15.0 | Structured logging |
| swift-nio | `1a69138cb7f2e63de709c9716e0348ffd6522ac7` | Local HTTP transport; Windows loopback wakeup support |
| swift-crypto | 3.12.0 | Cryptographic hashes and primitives |
| OpenAI tunnel-client | Build scripts pin and verify the helper artifact | Secure MCP Tunnel |
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
