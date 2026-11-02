#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import struct
import subprocess
import tempfile


MACH_O_MAGIC = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


def sign_runtime(root, identity, entitlements, hardened, timestamp):
    manifest_path = root / "runtime.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    node = manifest["node"]
    signed = 0
    signed_node = False
    for item in manifest["files"]:
        relative = PurePosixPath(item["path"])
        if relative.is_absolute() or ".." in relative.parts or "\\" in str(relative):
            raise ValueError("Unsafe path in embedded DSH manifest")
        binary = root.joinpath(*relative.parts)
        if not binary.is_file() or binary.is_symlink():
            raise ValueError(f"Missing embedded DSH file: {relative}")
        with binary.open("rb") as source:
            header = source.read(8)
            if header[:4] not in MACH_O_MAGIC:
                continue
            # Java class files share the universal Mach-O magic.
            if header[:4] in {bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")}:
                if len(header) < 8 or not 0 < struct.unpack(">I", header[4:8])[0] <= 32:
                    continue
        arguments = ["/usr/bin/codesign", "--force", "--sign", identity]
        if hardened:
            arguments.extend(["--options", "runtime"])
        if timestamp:
            arguments.append("--timestamp")
        if str(relative) == node:
            arguments.extend(["--entitlements", str(entitlements)])
        subprocess.run([*arguments, str(binary)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)
        checksum = hashlib.sha256()
        with binary.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(chunk)
        item["sha256"] = checksum.hexdigest()
        signed += 1
        signed_node = signed_node or str(relative) == node
    if not signed_node:
        raise ValueError("Embedded DSH Node executable is not a Mach-O binary")
    if {"arm64": "arm64", "x86_64": "x64"}.get(platform.machine()) == manifest["architecture"]:
        environment = os.environ.copy()
        for variable in ("NODE_OPTIONS", "NODE_PATH"):
            environment.pop(variable, None)
        node_binary = root.joinpath(*PurePosixPath(node).parts)
        for arguments in ([str(node_binary), "--version"],
                          [str(node_binary), str(root / "node_modules/pnpm/bin/pnpm.cjs"), "--version"]):
            subprocess.run(arguments, cwd=root, env=environment, check=True, timeout=60)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=root, prefix=".runtime-", delete=False
        ) as destination:
            temporary = destination.name
            json.dump(manifest, destination, ensure_ascii=False, indent=2)
            destination.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, manifest_path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Signed {signed} embedded DSH native components.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("identity")
    parser.add_argument("entitlements", type=Path)
    parser.add_argument("--hardened", action="store_true")
    parser.add_argument("--timestamp", action="store_true")
    arguments = parser.parse_args()
    sign_runtime(
        arguments.runtime.resolve(), arguments.identity, arguments.entitlements.resolve(),
        arguments.hardened, arguments.timestamp,
    )


if __name__ == "__main__":
    main()
