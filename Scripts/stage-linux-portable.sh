#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_directory="$1"
output="$2"
architecture="$3"
payload="$output/$architecture"
if [[ -e "$payload" ]]; then
  echo "Payload directory already exists: $payload" >&2
  exit 1
fi
mkdir -p "$payload/lib"
for executable in codex-bridge-linux-app codex-bridge-service; do
  install -m 755 "$binary_directory/$executable" "$payload/$executable"
  while IFS= read -r library; do
    case "$library" in
      */swift/*) cp -L "$library" "$payload/lib/" ;;
    esac
  done < <(ldd "$binary_directory/$executable" | awk '/=> \// { print $3 }')
done
shopt -s nullglob
for resource in "$binary_directory"/*.resources "$binary_directory"/*.bundle; do
  cp -a "$resource" "$payload/"
done
shopt -u nullglob
install -m 755 "$root/Linux/codex-bridge" "$payload/codex-bridge"
install -m 644 "$root/LICENSE" "$root/NOTICE" "$payload/"
"$root/Scripts/stage-linux-tunnel-client.sh" "$architecture" "$payload"
python3 "$root/Scripts/verify-linux-payload.py" "$payload" "$architecture"
node "$root/Scripts/verify-agent-runtime-resources.mjs" "$payload"
version="$(awk -F= '/^MARKETING_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2}' "$root/Config/Base.xcconfig")"
python3 - "$payload/BUILD-INFO.json" "$version" "$architecture" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({
    "appVersion": sys.argv[2], "platform": "linux", "architecture": sys.argv[3]
}, indent=2) + "\n")
PY
archive="codex-bridge-linux-$architecture-$version.tar.gz"
tar -C "$payload" -czf "$output/$archive" .
(cd "$output" && sha256sum "$archive" > "$archive.sha256")
