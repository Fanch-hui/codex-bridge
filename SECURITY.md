# Security

Codex Bridge executes local developer tools against explicitly registered projects. Path escape, credential exposure, approval bypass, task replay, and incorrect project/session binding are security issues.

## Reporting

Use the repository's [Security page](https://github.com/yeyuancc0-glitch/codex-bridge/security) for security reports. Include the affected version, operating system, expected behavior, actual behavior, and a minimal reproduction using synthetic data.

Do not attach credentials, authentication files, browser cookies, private keys, or unrelated project content to a report.

## Boundaries

- Local MCP uses loopback transport and authenticated client access.
- Project requests use registered project identifiers and validated paths.
- Service policy and explicit approvals control access; model-generated text does not grant permissions.
- Agent capabilities are checked against the installed provider and its connection probe.
- macOS credentials use Keychain; Windows credentials use Credential Manager.
- Tunnel Runtime Keys are passed to the helper through platform-specific process launch mechanisms and are excluded from task evidence.
- Direct execution uses project command policy, structured arguments, bounded I/O, and process lifecycle controls.

Platform adapters handle filesystem identity, process creation, IPC access, and network isolation. Effective access also depends on the installed agent and the permissions the user grants to it.

## Release verification

Release downloads include SHA-256 checksums. macOS packages are architecture-specific and use ad-hoc code signatures; v1.0.0 is not Apple-notarized. Windows packages include architecture-matched runtime components and a payload manifest.

The build verifies packaged helper identities and binary architecture. These checks do not replace project permissions or operating-system security controls.
