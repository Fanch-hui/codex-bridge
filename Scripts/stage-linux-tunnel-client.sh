#!/usr/bin/env bash
set -euo pipefail

architecture="$1"
destination="$2"
version=0.0.10
case "$architecture" in
  x64)
    upstream_architecture=amd64
    expected=b9e0388a343f2d7adeff3992f411a0bd3d916a64bc56534aac5fd15ac1b20cd5
    machine=62 ;;
  arm64)
    upstream_architecture=arm64
    expected=b842a9b2352eebd80514cf01a1fbb1c0d400a7d24a4015e85a7ea5f1aeaa5b30
    machine=183 ;;
  *) echo "Architecture must be x64 or arm64." >&2; exit 1 ;;
esac
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
archive="tunnel-client-v$version-linux-$upstream_architecture.zip"
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
  "https://github.com/openai/tunnel-client/releases/download/v$version/$archive" \
  --output "$temporary/helper.zip"
printf '%s  %s\n' "$expected" "$temporary/helper.zip" | sha256sum --check
mkdir -p "$destination"
python3 - "$temporary/helper.zip" "$destination/tunnel-client" "$machine" <<'PY'
from pathlib import Path
import struct
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    binary = archive.read('tunnel-client')
if binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != int(sys.argv[3]):
    raise SystemExit('Tunnel helper ELF architecture mismatch')
Path(sys.argv[2]).write_bytes(binary)
PY
chmod 755 "$destination/tunnel-client"
sha256sum "$destination/tunnel-client" | cut -d ' ' -f 1 > "$destination/tunnel-client.sha256"
"$destination/tunnel-client" --version
