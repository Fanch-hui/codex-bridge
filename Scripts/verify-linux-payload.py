#!/usr/bin/env python3
import hashlib
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
machine = {"x64": 62, "arm64": 183}[sys.argv[2]]
binaries = [root / name for name in (
    "codex-bridge-linux-app", "codex-bridge-service", "tunnel-client"
)]
binaries += list((root / "lib").glob("*.so*"))
for path in binaries:
    with path.open("rb") as source:
        header = source.read(64)
    if header[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", header, 18)[0] != machine:
        raise SystemExit(f"ELF architecture mismatch: {path.name}")
for resource in ("BridgeDesktopUI", "BridgeDeepSeekHarnessACP", "BridgePiRPC", "BridgeQoderSDK",
                 "BridgeDeepSeekHarnessDesktop"):
    if not any(path.is_dir() for path in root.glob(f"BridgeCore_{resource}.*")):
        raise SystemExit(f"Missing Swift resource bundle: {resource}")
digest = hashlib.sha256((root / "tunnel-client").read_bytes()).hexdigest()
if digest != (root / "tunnel-client.sha256").read_text().strip():
    raise SystemExit("Tunnel helper digest mismatch")
print(f"Verified {len(binaries)} ELF binaries and shared runtime resources.")
