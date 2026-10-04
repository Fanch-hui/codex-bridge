#!/usr/bin/env bash
set -euo pipefail

payload="$(cd "$1" && pwd)"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="${2:-}"
if [[ -n "$package" ]]; then
  package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
fi
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
export XDG_DATA_HOME="$temporary/data"
export XDG_CONFIG_HOME="$temporary/config"
export XDG_RUNTIME_DIR="$temporary/run"
mkdir -m 700 "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
export CODEX_BRIDGE_VERIFY_PAYLOAD="$payload"
export CODEX_BRIDGE_VERIFY_PACKAGE="$package"
export CODEX_BRIDGE_VERIFY_SCRIPTS="$scripts"
dbus-run-session -- bash -euo pipefail <<'SH'
python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(16))' |
  gnome-keyring-daemon --unlock --components=secrets >/dev/null
trap '"$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --shutdown-service || true' EXIT
timeout 30s "$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --ensure-service
if [[ -n "$CODEX_BRIDGE_VERIFY_PACKAGE" ]]; then
  python3 -B "$CODEX_BRIDGE_VERIFY_SCRIPTS/verify-linux-package-upgrade.py" \
    "$CODEX_BRIDGE_VERIFY_PAYLOAD" "$CODEX_BRIDGE_VERIFY_PACKAGE"
fi
timeout 40s "$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --shutdown-service
trap - EXIT
echo 'Packaged desktop connected over Unix IPC and waited for service shutdown.'
SH
