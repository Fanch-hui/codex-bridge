#!/usr/bin/env python3
"""Install the maintained Agent Reach overlay into existing Skill directories."""

import argparse
from pathlib import Path
import shutil


def install(destination: Path) -> None:
    source = Path(__file__).resolve().parents[1] / "Examples" / "AgentReachSkill"
    if not (destination / "SKILL.md").is_file():
        raise SystemExit(f"Agent Reach Skill is not installed at {destination}")
    files = [source / "SKILL.md", *sorted((source / "references").glob("*.md"))]
    files.extend(sorted((source / "scripts").glob("*.sh")))
    for file in files:
        target = destination / file.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    for channel in sorted((source / "channels").iterdir()):
        shutil.copytree(channel, destination.parent / channel.name, dirs_exist_ok=True)
    print(f"Installed Agent Reach Skill and channel actions: {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("skill_directory", type=Path, nargs="+",
                        help="Existing Agent Reach Skill directory to update")
    args = parser.parse_args()
    for directory in args.skill_directory:
        install(directory.expanduser().resolve())


if __name__ == "__main__":
    main()
