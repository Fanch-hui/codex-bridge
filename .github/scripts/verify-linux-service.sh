#!/usr/bin/env bash
set -euo pipefail

payload="$(cd "$1" && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
export XDG_DATA_HOME="$temporary/data"
export XDG_CONFIG_HOME="$temporary/config"
export XDG_RUNTIME_DIR="$temporary/run"
mkdir -m 700 "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
export CODEX_BRIDGE_VERIFY_PAYLOAD="$payload"
dbus-run-session -- bash -euo pipefail <<'SH'
python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(16))' |
  gnome-keyring-daemon --unlock --components=secrets >/dev/null
trap '"$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --shutdown-service || true' EXIT
timeout 30s "$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --ensure-service
timeout 15s "$CODEX_BRIDGE_VERIFY_PAYLOAD/codex-bridge" --shutdown-service
trap - EXIT
echo 'Packaged desktop connected to its service over Unix IPC and requested graceful shutdown.'
SH
