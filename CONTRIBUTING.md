# Contributing to Codex Bridge

Codex Bridge accepts focused changes that preserve its local-first architecture, public interfaces and persisted data.

## Before changing code

1. Read `DESIGN.md`, any instructions present in the checkout, and the relevant source and product documentation.
2. Keep application use cases in `BridgeServiceApplication`, persistence in `BridgeServiceCore`, and platform assembly and IPC routing in `BridgeServiceHost`. Request controllers call the application facade for business operations; provider installation metadata and transport subscriptions remain host responsibilities.
3. Implement desktop pages in `BridgeDesktopUI`. macOS, Windows and Linux hosts adapt the same page state and commands; platform APIs belong in their host modules.
4. Preserve API and stored-data compatibility with additive defaults and explicit migrations.
5. Keep credentials, browser data, project secrets, local support bundles and temporary work records out of commits.

## Local verification

Run checks appropriate to the affected behavior. All SwiftPM builds and tests use `swiftbuild`; do not build the same checkout concurrently.

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore --build-system swiftbuild
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources App Service
```

Strict Swift formatting is required before committing. Tests should verify state transitions, transactions, filesystem identities, process lifecycle or protocol behavior. Use focused fixtures when native credentials or third-party services are unnecessary. Product UI interaction and final experience are manually accepted by the user.

The public `win` branch contains production source. Test suites, fixtures and development verification tools are maintained in the development checkout. When those files are present, run the affected suites and include them in formatting checks:

```bash
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --build-system swiftbuild --filter '<AffectedTestClass>'
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests App Service UITests
```

In the development checkout, shared desktop JavaScript changes use the relevant `Scripts/test-desktop-*.cjs` tests with `node --test`. Pi and Qoder runtime changes also require their resource digest checks and affected Node protocol tests. MCP contract changes use `Scripts/verify-mcp-inspector.sh`.

macOS host changes can be built with:

```bash
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` when using another complete Xcode installation. Linux and Windows toolchain, build and package checks are documented in [LINUX.md](docs/LINUX.md) and [WINDOWS_PORT.md](docs/WINDOWS_PORT.md).

## Continuous integration

The public platform workflows use native architecture runners:

- `macos.yml` builds macOS arm64 and x86_64 release packages on pushes and manual runs.
- `windows.yml` builds x64 and arm64 portable ZIPs and Inno Setup installers, checks Agent CLI contracts and service startup, and verifies installation, same-version replacement, IPC and uninstall.
- `linux.yml` builds x64 and arm64 tar.gz and deb packages, then verifies the installed package, service IPC and uninstall. Its development checks run when the corresponding test fixtures are available.
- `mcp-registry.yml` publishes and verifies the MCP bundle after a release is published.

Development CI additionally runs Swift tests, strict formatting, shared desktop logic tests, MCP contract checks, dependency-lock checks and public-source export checks.

Report local tests, native platform checks, installer checks and CI as separate evidence. A source build alone does not establish installed-app behavior. Release acceptance is described in [RELEASE.md](docs/RELEASE.md).

## Commits and pull requests

- Commit an independent, working change after its necessary checks, with a concise description of the resulting behavior.
- Explain the user-visible outcome and any affected security or state invariant. Include the verification commands and results.
- Keep changes within the task scope; retain durable regression tests and clean up temporary fixtures.
- Public source is exported from tracked Git blobs with `Scripts/export-public-source.py`. Follow the export rules rather than merging a development branch directly into the trimmed public `win` branch.

Report security issues privately as described in [SECURITY.md](SECURITY.md).
