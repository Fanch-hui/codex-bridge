#!/usr/bin/env python3
"""Check installed OpenCLI coverage and execute each action's non-network help."""

import argparse
import json
from pathlib import Path
import subprocess

import yaml


def read_manifest(path: Path) -> dict:
    return yaml.safe_load((path / "SKILL.md").read_text().split("---", 2)[1])


def check_channel(skill: Path, commands: list[dict]) -> int:
    manifest = read_manifest(skill)
    site = manifest["name"].removeprefix("agent-reach-")
    expected = {c["name"] for c in commands if c["site"] == site and c["access"] == "read"}
    actions = manifest["actions"]
    names = {a["name"] for a in actions}
    assert names == {site + "_" + name.replace("-", "_") for name in expected}, site
    assert len(actions) <= 64, site
    assert all(a["network_requirement"] == "required" for a in actions), site
    for action in actions:
        result = subprocess.run(
            [action["interpreter"], str(skill / action["script"]), "--help", "-f", "json"],
            capture_output=True, text=True, timeout=15, check=True,
        )
        help_data = json.loads(result.stdout)
        assert help_data["access"] == "read", action["name"]
        assert help_data["command"] == (
            "opencli " + site + " " + action["name"][len(site) + 1:].replace("_", "-")
        ), action["name"]
    print(f"{site}: {len(actions)} read actions verified", flush=True)
    return len(actions)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    commands = json.loads(subprocess.check_output(["opencli", "list", "-f", "json"], text=True))
    total = sum(check_channel(p, commands) for p in sorted((args.root / "channels").iterdir()))
    legacy = read_manifest(args.root)["actions"]
    names = {a["name"] for a in legacy}
    assert {"doctor", "check_update", "reddit_search", "reddit_read", "reddit_subreddit",
            "twitter_search", "xiaohongshu_search", "xiaohongshu_note", "bilibili_search",
            "bilibili_video", "bilibili_subtitle", "facebook_search", "facebook_profile",
            "instagram_search", "instagram_profile", "instagram_user"} <= names
    assert len(legacy) <= 64
    assert all(a["network_requirement"] == "required" for a in legacy)
    print(f"Verified {total} channel actions and {len(legacy)} main Skill actions.")


if __name__ == "__main__":
    main()
