# Dependencies

The package manifests and `Package.resolved` define the Swift dependencies used to build Codex Bridge. Release packages include an SPDX software bill of materials and SHA-256 checksums.

| Component | Selection | Use |
| --- | --- | --- |
| MCP Swift SDK | 0.12.1, vendored with Windows compatibility changes | MCP protocol and transport |
| GRDB.swift | 7.11.1 | SQLite persistence |
| swift-log | 1.15.0 | Structured logging |
| swift-nio | `1a69138cb7f2e63de709c9716e0348ffd6522ac7` | Local HTTP transport; Windows loopback wakeup support |
| swift-crypto | 3.12.0 | Cryptographic hashes and primitives |
| OpenAI tunnel-client | 0.0.19, commit `01d67bb4da0d8359b808b4761f8db171ab682cd7` | Secure MCP Tunnel |
| WebView2 SDK | 1.0.4191.47 | Windows embedded browser loader |
| zcode-api and proxy adaptations | `158e7653b738cbed0996243eeabd26f816638e81`, included in dsh-zcode 0.2.1 | ZCode model connection; CC BY-NC-SA 4.0 |

macOS uses WKWebView and XPC. Windows uses WebView2 and named pipes. Linux uses GTK 3 / WebKitGTK 4.1 and Unix domain sockets. All three platforms load the shared local `BridgeDesktopUI` resources.

Codex, Claude Code, OpenCode, DeepSeek Harness, Antigravity, Pi, and Qoder run as separate agent processes, while the built-in Workbench uses the bundled `EmbeddedDSH` runtime. Available capabilities are determined by each installed agent's entrypoint and runtime probe. DeepSeek Harness uses a Node runtime and ACP configuration managed by the Bridge adapter.

## Packaging

- Swift runtime files must match the selected Swift toolchain and target architecture.
- Windows packages include matching SQLite, WebView2 loader, and app-local VC runtime files.
- Tunnel helper binaries are checked for the expected architecture and SHA-256 before staging.
- macOS signs embedded executable components before signing the app, then records the final helper digest.
- Application data and browser profiles remain outside the installation payload.

See [NOTICE](../NOTICE) and the bundled dependency licenses for third-party attribution.

## ZCode proxy license and source

The embedded dsh-zcode package includes zcode-api by TriDefender and contributors and adaptations of its proxy. These components are licensed under [CC BY-NC-SA 4.0](../Integrations/EmbeddedDSH/licenses/ZCODE-UPSTREAM-LICENSE), which requires attribution, noncommercial use and share-alike. The adapter's remaining source is Apache-2.0; see the [third-party notices](../Integrations/EmbeddedDSH/licenses/ZCODE-THIRD-PARTY-NOTICES.md) for attribution and component details.

Release packages include the license and notices in `EmbeddedDSH/licenses/`, and the corresponding upstream and integration source in `EmbeddedDSH/vendor/dsh-zcode-0.2.1.tgz` (the archive's `package/vendor/zcode-api/` and `package/integration/` directories). On macOS, `EmbeddedDSH` is in the app's `Contents/Resources/`; on Windows and Linux it is in the installed payload.

## Tunnel helper supply pin

The official v0.0.19 full-client ZIP files were checked against GitHub Release asset digests on 2026-11-06. Build and staging scripts pin these SHA-256 values and preserve upstream LICENSE, NOTICE, third-party licenses and SPDX metadata. The macOS Universal 2 helper is derived from the two verified thin executables.

| Platform | ZIP SHA-256 | Client SHA-256 |
| --- | --- | --- |
| darwin-amd64 | `dff97674c77cac59e6ab3d901e6cff50fb17a5784c01d8959d1f4adb3afdf4bf` | `dfd9f50aa6846ba76223d4ceb86ab9408b794881b650b000ec0ef6fd2a8b775b` |
| darwin-arm64 | `2243d024b77af8ee4b4ab7a1447949e5fc8d82bcd2d51b178927f2da9e47ecfd` | `4a82a4591933241850966ab3484cb39e65fad11b7e83b43891f6599f9638bd7f` |
| windows-amd64 | `1d0ecc3a54f2a51e27a635ac155f40fbb95df58c52cdeddf6c75532cc0bbeb25` | `7e93a39a567c87154a0aef2091b81100d78f9093c4603412cc2b55bed3dfe5ea` |
| windows-arm64 | `a054bfb19d72b446cc9802a7987a17eab517502355d27b18e51814bbb0b32731` | `501ae14cfcc67915f29233988599eac1903946c4bf024f3e24d6669d01ecf6d0` |
| linux-amd64 | `9ee9448592345a9dd1517fb79791ab54d24f051142eb92bcbe8cd355effc9142` | `56d0120886ce91bfe31e7a5600f6a6594199a02e9b3eac671d5da0d7480c97a3` |
| linux-arm64 | `5a19e556c4a8736ab7a6fde6f0568f6e7411fa2dff21186fc15bc30e9b98a603` | `8a50b25d6055bc6e3e3a5c18c098637ab2be63f6e453b8ebebd02433deadba04` |

Official source and artifacts: [OpenAI tunnel-client v0.0.19](https://github.com/openai/tunnel-client/releases/tag/v0.0.19).
