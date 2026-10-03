#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version="$(awk -F= '/^MARKETING_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2}' "$root/Config/Base.xcconfig")"
package="$1/CodexBridge-Linux-$2-$version.deb"
if [[ "$(dpkg-query --show --showformat='${Status}' codex-bridge 2>/dev/null || true)" == 'install ok installed' ]]; then
  echo 'Package acceptance requires a container without Codex Bridge installed.' >&2
  exit 1
fi
trap 'dpkg --remove codex-bridge >/dev/null || true' EXIT
dpkg --install "$package"
installed_version="$(dpkg-query --show --showformat='${Version}' codex-bridge)"
if [[ "$installed_version" != "$version" ]]; then
  echo "Installed version mismatch: $installed_version, expected $version." >&2
  exit 1
fi
python3 - "$version" <<'PY'
import json
from pathlib import Path
import sys

info = json.loads(Path('/opt/codex-bridge/BUILD-INFO.json').read_text())
if info['appVersion'] != sys.argv[1]:
    raise SystemExit('Installed payload version does not match the release version.')
PY
"$root/.github/scripts/verify-linux-service.sh" /opt/codex-bridge
dpkg --remove codex-bridge
if [[ "$(dpkg-query --show --showformat='${Status}' codex-bridge 2>/dev/null || true)" == 'install ok installed' ]]; then
  echo 'Codex Bridge remains installed after package removal.' >&2
  exit 1
fi
trap - EXIT
echo "Installed Codex Bridge $version, verified Unix IPC, and removed the package."
