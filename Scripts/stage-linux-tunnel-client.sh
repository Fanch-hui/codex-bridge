#!/usr/bin/env bash
set -euo pipefail

architecture="$1"
destination="$2"
version=0.0.18
case "$architecture" in
  x64)
    upstream_architecture=amd64
    expected=3c82307316acd93c88a384b62af1d81d3f4cb0efa975f9c0bfaef922866a04c4
    binary_digest=55c48566e682473a602eea4951978d27acc0f2c8de2340b684a8b114feba7a83
    licenses_digest=338065faea9beccb5d218b4141a7876e3f18bee34a0844ee33001f1229bc6650
    sbom_digest=08a10a7005c3ce9fae4af382e7d7df90c04d31e7902369c1d63caa918b2216ff
    machine=62 ;;
  arm64)
    upstream_architecture=arm64
    expected=a5f3d70efc75f5e66ab5c67c44d272aa80b2736f93f875f165140517750ec035
    binary_digest=5e0c8e2cc3b49ea718a81866001625ad8ea4a19771ec3c4efaaccda0c71e715a
    licenses_digest=ae12231037484059009e2d2b590f9f684660910e07e2a7689af800983abd87da
    sbom_digest=5e5b083963ac6b7574c6d93ba038469937a9793c7f45231afbc5d3a4940b7f10
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
