#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -d "$root/Packages/BridgeCore/Tests/BridgeServiceHostLinuxTests" ]]; then
  echo 'Linux platform tests are supplied by the development source tree.'
  exit 0
fi
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
export XDG_DATA_HOME="$temporary/data"
export XDG_CONFIG_HOME="$temporary/config"
export XDG_RUNTIME_DIR="$temporary/run"
mkdir -m 700 "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
export CODEX_BRIDGE_TEST_SECRET_SERVICE=1
export CODEX_BRIDGE_TEST_PACKAGE="$root/Packages/BridgeCore"
python3 -B "$root/Scripts/test_linux_package_maintenance.py"
dbus-run-session -- bash -euo pipefail <<'SH'
python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(16))' |
  gnome-keyring-daemon --unlock --components=secrets >/dev/null
swift test --package-path "$CODEX_BRIDGE_TEST_PACKAGE" --build-system swiftbuild \
  -Xswiftc -DSQLITE_DISABLE_SNAPSHOT \
  --filter 'LinuxServiceIPCTests|LinuxShutdownOptionsTests|LinuxSecretServiceStoreTests|LinuxNetworkSandboxTests|CodexLinuxExecutableResolverTests|LinuxTunnelRuntimeTests|ManagedStdioProcessPOSIXTests'
SH
