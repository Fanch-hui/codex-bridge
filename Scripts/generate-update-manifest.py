#!/usr/bin/env python3
"""Generate the latest.json feed consumed by the desktop update client."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path, PurePosixPath
from typing import NoReturn
from urllib.parse import quote


REPOSITORY = "yeyuancc0-glitch/codex-bridge"
PLATFORMS = {"macos", "windows"}
ARCHITECTURES = {"arm64", "x64"}
KINDS = {"app", "installer", "portable"}
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--notes", default="")
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument(
        "--asset",
        nargs=4,
        action="append",
        metavar=("PLATFORM", "ARCHITECTURE", "KIND", "FILE"),
        required=True,
    )
    return parser.parse_args()


def fail(message: str) -> NoReturn:
    raise SystemExit(f"generate-update-manifest.py: {message}")


def digest_and_size(path: Path) -> tuple[str, int]:
    if not path.is_file() or path.is_symlink():
        fail(f"asset is not a regular file: {path}")
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def verify_asset_shape(platform: str, architecture: str, kind: str, path: Path) -> None:
    if platform not in PLATFORMS:
        fail(f"unsupported platform: {platform}")
    if architecture not in ARCHITECTURES:
        fail(f"unsupported architecture: {architecture}")
    if kind not in KINDS:
        fail(f"unsupported asset kind: {kind}")
    if platform == "macos" and kind != "app":
        fail("macOS assets must use kind app")
    if platform == "windows" and kind == "app":
        fail("Windows assets must use kind installer or portable")
    if platform == "macos":
        if path.suffix.lower() != ".zip":
            fail(f"macOS app asset must be a ZIP: {path}")
        try:
            with zipfile.ZipFile(path) as archive:
                names = [PurePosixPath(name) for name in archive.namelist()]
        except zipfile.BadZipFile as error:
            fail(f"invalid macOS app ZIP {path}: {error}")
        if not any(name.parts and name.parts[0] == "CodexBridge.app" for name in names):
            fail(f"macOS app ZIP must contain a CodexBridge.app root: {path}")


def asset_record(
    platform: str, architecture: str, kind: str, path: Path, tag: str
) -> dict[str, object]:
    verify_asset_shape(platform, architecture, kind, path)
    digest, size = digest_and_size(path)
    filename = quote(path.name, safe="-_.()")
    url = f"https://github.com/{REPOSITORY}/releases/download/{quote(tag, safe='-._')}/{filename}"
    return {
        "platform": platform,
        "architecture": architecture,
        "kind": kind,
        "url": url,
        "sha256": digest,
        "size": size,
    }


def main() -> None:
    arguments = parse_args()
    if not VERSION_RE.fullmatch(arguments.version):
        fail(f"version must be numeric major.minor.patch: {arguments.version}")
    if not arguments.tag or any(character in arguments.tag for character in "\r\n"):
        fail("tag must be a non-empty single line")
    if arguments.notes_file:
        try:
            notes = arguments.notes_file.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read notes file: {error}")
    else:
        notes = arguments.notes

    assets = []
    seen: set[tuple[str, str, str]] = set()
    for platform, architecture, kind, raw_path in arguments.asset:
        identity = (platform, architecture, kind)
        if identity in seen:
            fail(f"duplicate asset identity: {'/'.join(identity)}")
        seen.add(identity)
        assets.append(
            asset_record(platform, architecture, kind, Path(raw_path), arguments.tag)
        )

    manifest = {"version": arguments.version, "notes": notes, "assets": assets}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        fail(str(error))
