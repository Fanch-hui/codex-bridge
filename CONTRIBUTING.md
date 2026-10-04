# Contributing to Codex Bridge

Codex Bridge accepts focused changes that preserve its local-first architecture, public interfaces and persisted data.

## Before changing code

1. Read the root `AGENTS.md`, any instructions in the affected directory, and the relevant source and product documentation.
2. Keep application use cases in `BridgeServiceApplication`, persistence in `BridgeServiceCore`, and platform assembly and IPC routing in `BridgeServiceHost`. Request controllers call the application facade for business operations; provider installation metadata and transport subscriptions remain host responsibilities.
3. Implement desktop pages in `BridgeDesktopUI`. macOS, Windows and Linux hosts adapt the same page state and commands; platform APIs belong in their host modules.
4. Preserve API and stored-data compatibility with additive defaults and explicit migrations.
5. Keep credentials, browser data, project secrets, local support bundles and temporary work records out of commits.

## Local verification

Run checks appropriate to the affected behavior. All SwiftPM builds and tests use `swiftbuild`; do not build the same checkout concurrently.

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore --build-system swiftbuild
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --build-system swiftbuild --filter '<AffectedTestClass>'
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests App Service UITests
```

Strict Swift formatting is required before committing. Tests should verify state transitions, transactions, filesystem identities, process lifecycle or protocol behavior. Use focused fixtures when native credentials or third-party services are unnecessary. Product UI interaction and final experience are manually accepted by the user.

For shared desktop JavaScript, run the relevant `Scripts/test-desktop-*.cjs` tests with `node --test`. Changes to Pi or Qoder runtime resources also require their resource digest checks and affected Node protocol tests.

MCP contract changes use `Scripts/verify-mcp-inspector.sh`. macOS host changes can be built with:

```bash
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` when using another complete Xcode installation. Linux and Windows toolchain, build and package checks are documented in [LINUX.md](docs/LINUX.md) and [WINDOWS_PORT.md](docs/WINDOWS_PORT.md).

## Continuous integration

`.github/workflows/ci.yml` runs Swift tests, strict formatting, shared desktop logic tests, MCP contract checks, dependency-lock checks, public-source export checks and unsigned macOS builds and archives. `.github/workflows/windows.yml` and `.github/workflows/linux.yml` use native architecture runners for their platform builds, service checks and installer acceptance. The Linux development workflow also runs its isolated platform test suites.

Report local tests, native platform checks, installer checks and CI as separate evidence. A source build alone does not establish installed-app behavior. Release acceptance is described in [RELEASE.md](docs/RELEASE.md).

## Commits and pull requests

- Commit an independent, working change after its necessary checks, with a concise description of the resulting behavior.
- Explain the user-visible outcome and any affected security or state invariant. Include the verification commands and results.
- Keep changes within the task scope; retain durable regression tests and clean up temporary fixtures.
- Public source is exported from tracked Git blobs with `Scripts/export-public-source.py`. Follow the export rules rather than merging a development branch directly into the trimmed public `win` branch.

Report security issues privately as described in [SECURITY.md](SECURITY.md).
