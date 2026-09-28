import re
from pathlib import Path


def remove_test_steps(workflow):
    lines = workflow.splitlines(keepends=True)
    result = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if re.match(r"^\s*- name:\s*Smoke\b", line):
            indent = len(line) - len(line.lstrip())
            index += 1
            while index < len(lines):
                candidate = lines[index]
                candidate_indent = len(candidate) - len(candidate.lstrip())
                if candidate.strip() and candidate_indent == indent and candidate.lstrip().startswith("- name:"):
                    break
                index += 1
            continue
        if re.match(r"^      ui_smoke:\s*(?:#.*)?\n?$", line):
            index += 1
            while index < len(lines):
                candidate = lines[index]
                candidate_indent = len(candidate) - len(candidate.lstrip())
                if candidate.strip() and candidate_indent <= 6:
                    break
                index += 1
            continue
        if re.match(r"^\s*run_tests\s*:", line):
            index += 1
            continue
        result.append(line)
        index += 1
    for index, line in enumerate(result):
        if not re.match(r"^    inputs:\s*(?:#.*)?\n?$", line):
            continue
        descendants = result[index + 1 :]
        has_input = any(
            candidate.strip()
            and len(candidate) - len(candidate.lstrip()) > 4
            for candidate in descendants
            if len(candidate) - len(candidate.lstrip()) > 0
        )
        if not has_input:
            del result[index]
        break
    return "".join(result)


def transform_workflow(path):
    path = Path(path)
    path.write_text(remove_test_steps(path.read_text()))


def verify_workflow(path):
    source = Path(path).read_text()
    forbidden = (
        "matrix.run_tests", "Packages/BridgeCore/Tests", ".github/scripts/test-", "ui_smoke"
    )
    found = [value for value in forbidden if value in source]
    if found:
        raise ValueError(f"Windows workflow references excluded test assets: {found}")
    required = (
        "Build service and Windows shell",
        "Stage Windows portable package",
        "Build Windows EXE installer",
    )
    missing = [value for value in required if value not in source]
    if missing:
        raise ValueError(f"Windows production packaging steps are missing: {missing}")


def verify_mcp_registry_workflow(path, export_root):
    source = Path(path).read_text()
    required = (
        "gh release download",
        "--pattern server.json",
        "node Scripts/verify-mcpb-release.mjs",
        '"$RUNNER_TEMP/mcp-package/server.json"',
    )
    missing = [value for value in required if value not in source]
    if missing:
        raise ValueError(f"MCP Registry workflow does not use release metadata: {missing}")
    if not (Path(export_root) / "Scripts/verify-mcpb-release.mjs").is_file():
        raise ValueError("MCP Registry verifier is missing from the public source tree")
