import argparse
from pathlib import Path
import subprocess
import sys

from public_source_export import export_source, resolve_ref, verify_source


def main():
    parser = argparse.ArgumentParser(description="Export the public production source tree from a Git ref.")
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="create a public source directory")
    export.add_argument("--ref", default="HEAD", help="tracked Git commit, branch, or tag (default: HEAD)")
    export.add_argument("--output", required=True, help="new output directory, relative to the repository root")
    verify = commands.add_parser("verify", help="verify an existing public source directory")
    verify.add_argument("--ref", default="HEAD", help="source Git commit, branch, or tag (default: HEAD)")
    verify.add_argument("--output", required=True, help="export directory to verify")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        commit = resolve_ref(root, arguments.ref)
        if arguments.command == "export":
            commit, count = export_source(root, commit, arguments.output)
            print(f"Exported {count} tracked files from {commit} to {arguments.output}")
        else:
            count = verify_source(root, commit, arguments.output)
            print(f"Verified {count} exported files against {commit}")
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Public source export failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
