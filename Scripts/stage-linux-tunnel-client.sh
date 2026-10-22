#!/usr/bin/env bash
set -euo pipefail

architecture="$1"
destination="$2"
version=0.0.17
case "$architecture" in
  x64)
    upstream_architecture=amd64
    expected=bd6a57c6c0511644267cafadd13ffdb53ece0d753e0b88857f957e78a8fbc793
    binary_digest=e163ff89cfc3c8bd9d196fe3fd622ba39d009af9935e38432790f39eb9b6db01
    licenses_digest=22bdf95290d3b39d0274a608b5347c9b343b3f4147be5106db76ff677e2814be
    sbom_digest=59fad7b2ae79241dfc9d17bbc207c1c016a25c5e2fc98c3945c137ae221f7270
    machine=62 ;;
  arm64)
    upstream_architecture=arm64
    expected=f5060d0b63663268aab3ca310cb6110fa14867981db2b0657f679d8836a2daa0
    binary_digest=683afd34c71fca51670cf3d79d47abd5c717ecb3a52d721f3449c3ed41f36c60
    licenses_digest=5889ca9bd77eb3a62b9c0caac5a4c25df1d7ae02c1f64281a36924b711debb85
    sbom_digest=490ebb7666e6db4827f50bb058d798949a2ee04e837aa0efb1966633e0a41af1
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
python3 - "$temporary/helper.zip" "$destination" "$machine" "$archive" \
  "$binary_digest" "$licenses_digest" "$sbom_digest" <<'PYTHON'
from pathlib import Path
import hashlib
import stat
import struct
import sys
import zipfile

archive_path, destination, machine, archive_name, binary_hash, licenses_hash, sbom_hash = sys.argv[1:]
archive_base = archive_name.removesuffix('.zip')
members = {
    'LICENSE': ('LICENSE', 'f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4'),
    'NOTICE': ('NOTICE', '1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2'),
    'THIRD-PARTY-LICENSES.txt': (archive_base + '-licenses.txt', licenses_hash),
    'SBOM.spdx.json': (archive_base + '.spdx.json', sbom_hash),
}
with zipfile.ZipFile(archive_path) as archive:
    expected = {'tunnel-client', 'cloudflared', 'cloudflared-manifest.json'} | {
        name for name, _ in members.values()
    }
    entries = archive.infolist()
    if len(entries) != len(expected) or {entry.filename for entry in entries} != expected:
        raise SystemExit('Unexpected Tunnel helper archive members')
    if any(not stat.S_ISREG(entry.external_attr >> 16) for entry in entries):
        raise SystemExit('Tunnel helper archive contains an irregular member')
    binary = archive.read('tunnel-client')
    if hashlib.sha256(binary).hexdigest() != binary_hash:
        raise SystemExit('Tunnel helper binary SHA-256 mismatch')
    if binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != int(machine):
        raise SystemExit('Tunnel helper ELF architecture mismatch')
    attribution = {}
    for output, (name, digest) in members.items():
        data = archive.read(name)
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit('Tunnel helper attribution SHA-256 mismatch: ' + output)
        attribution[output] = data
root = Path(destination)
(root / 'tunnel-client').write_bytes(binary)
(root / 'TunnelClient').mkdir(exist_ok=True)
for name, data in attribution.items():
    (root / 'TunnelClient' / name).write_bytes(data)
PYTHON
chmod 755 "$destination/tunnel-client"
sha256sum "$destination/tunnel-client" | cut -d ' ' -f 1 > "$destination/tunnel-client.sha256"
"$destination/tunnel-client" --version
