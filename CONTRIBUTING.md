# Contributing to Codex Bridge

Codex Bridge accepts focused changes that preserve its local-first architecture, public interfaces and persisted data.

## Before changing code

1. Read `DESIGN.md`, any instructions in the affected directory, and the relevant source and product documentation.
2. Keep application use cases in `BridgeServiceApplication`, persistence in `BridgeServiceCore`, and platform assembly and IPC routing in `BridgeServiceHost`. Request controllers call the application facade for business operations; provider installation metadata and transport subscriptions remain host responsibilities.
3. Implement desktop pages in `BridgeDesktopUI`. macOS, Windows and Linux hosts adapt the same page state and commands; platform APIs belong in their host modules.
4. Preserve API and stored-data compatibility with additive defaults and explicit migrations.
5. Keep credentials, browser data, project secrets, local support bundles and temporary work records out of commits.

## Local verification

Run checks appropriate to the affected behavior. All SwiftPM builds and tests use `swiftbuild`; do not build the same checkout concurrently.

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore --build-system swiftbuild
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --build-system swiftbuild --filter '<AffectedTestClass>'
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests App Service
```

Strict Swift formatting is required before committing. Tests should verify state transitions, transactions, filesystem identities, process lifecycle or protocol behavior. Use focused fixtures when native credentials or third-party services are unnecessary. Product UI interaction and final experience are manually accepted by the user.

macOS host changes can be built with:

```bash
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` when using another complete Xcode installation. Linux and Windows toolchain, build and package checks are documented in [LINUX.md](docs/LINUX.md) and [WINDOWS_PORT.md](docs/WINDOWS_PORT.md).

## Continuous integration

Pull requests and pushes to `win` run the platform workflows under `.github/workflows`:

- `macos.yml` runs the SwiftPM test suite on arm64 and x86_64 runners for pushes and pull requests; pushes additionally build and upload release packages for both architectures.
- `windows.yml` builds the portable ZIP and Inno Setup installer, runs the SwiftPM test suite in Release configuration, and verifies the installed Agent CLI contracts on x64 and arm64 runners.
- `linux.yml` builds the tar.gz and deb packages and runs the SwiftPM test suite plus the development platform checks (`.github/scripts/verify-linux-*.sh`) on x64 and arm64 inside a `swift:6.3.3-noble` container.
- `mcp-registry.yml` publishes the MCP server bundle to the official MCP Registry after a release is published; it is not part of code review.

The workflows use a read-only repository token and do not load Runtime Keys, ChatGPT credentials, signing identities or notarization credentials. A green workflow proves source, protocol and unsigned native-build compatibility on those runner images; it does not replace the signed release or clean-Mac acceptance in [docs/RELEASE.md](docs/RELEASE.md).

Report local tests, native platform checks, installer checks and CI as separate evidence. A source build alone does not establish installed-app behavior. Release acceptance is described in [RELEASE.md](docs/RELEASE.md).

## Commits and pull requests

- Commit an independent, working change after its necessary checks, with a concise description of the resulting behavior.
- Explain the user-visible outcome and any affected security or state invariant. Include the verification commands and results.
- Keep changes within the task scope; retain durable regression tests and clean up temporary fixtures.
- Public source is exported from tracked Git blobs with `Scripts/export-public-source.py`. Follow the export rules rather than merging a development branch directly into the trimmed public `win` branch.

Report security issues privately as described in [SECURITY.md](SECURITY.md).
