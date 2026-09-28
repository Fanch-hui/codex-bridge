import re
from pathlib import Path


def _skip(text, index):
    if text.startswith("<#", index):
        end = text.find("#>", index + 2)
        return len(text) if end < 0 else end + 2
    if text[index] == "#":
        end = text.find("\n", index)
        return len(text) if end < 0 else end
    quote = text[index]
    if quote not in {"'", '"'}:
        return index
    index += 1
    while index < len(text):
        if quote == '"' and text[index] == "`":
            index += 2
        elif quote == "'" and text.startswith("''", index):
            index += 2
        elif text[index] == quote:
            return index + 1
        else:
            index += 1
    return index


def _matching_brace(text, opening):
    depth = 0
    index = opening
    while index < len(text):
        skipped = _skip(text, index)
        if skipped != index:
            index = skipped
            continue
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError(f"Unclosed PowerShell block at offset {opening}")


def _remove_condition_block(text, condition):
    match = re.search(condition, text)
    if not match:
        raise ValueError("Expected Windows packaging condition was not found")
    opening = text.find("{", match.start(), match.end())
    closing = _matching_brace(text, opening) - 1
    line_start = text.rfind("\n", 0, match.start()) + 1
    body_start = text.find("\n", opening, closing) + 1
    closing_line_start = text.rfind("\n", 0, closing) + 1
    closing_line_end = text.find("\n", closing)
    if body_start == 0 or text[closing + 1 : closing_line_end].strip():
        raise ValueError("Windows packaging condition must use standalone braces")

    body = text[body_start:closing_line_start]
    dedented = []
    for line in body.splitlines(keepends=True):
        if line.strip():
            if not line.startswith("    "):
                raise ValueError("Unexpected indentation in Windows packaging body")
            line = line[2:]
        dedented.append(line)
    return text[:line_start] + "".join(dedented) + text[closing_line_end + 1 :]


def transform_windows_build_script(path):
    path = Path(path)
    source = path.read_text()
    source = source.replace(" [-Test]", "")
    source = re.sub(r"(?m)^\s*\[switch\]\$Test,\n", "", source)
    source = re.sub(r'(?m)^\s*\[string\]\$TestFilter = "",\n', "", source)
    condition = re.compile(
        r"if\s*\(\$Test\s+-or\s+-not\s+\[string\]::IsNullOrWhiteSpace\(\$TestFilter\)\)\s*\{"
    )
    spans = []
    for match in condition.finditer(source):
        opening = source.find("{", match.start(), match.end())
        end = _matching_brace(source, opening)
        left = source.rfind("\n", 0, match.start()) + 1
        right = source.find("\n", end)
        spans.append((left, len(source) if right < 0 else right + 1))
    for left, right in reversed(spans):
        source = source[:left] + source[right:]
    source = _remove_condition_block(
        source,
        r"if\s*\(-not\s+\$Test\s+-or\s+\$Installer\s+-or\s+-not\s+"
        r"\[string\]::IsNullOrWhiteSpace\(\$TunnelClientDir\)\)\s*\{",
    )
    source = source.replace(
        "  # Test-only runs stop here: packaging needs the Tunnel helper, which may have\n"
        "  # to be downloaded, and tests do not consume the portable package.\n",
        "",
    )
    path.write_text(source)


def verify_windows_build_script(path):
    source = Path(path).read_text()
    forbidden = ("$Test", "TestFilter", "swift test", "BridgeDomainTests", "UITests")
    found = [value for value in forbidden if value in source]
    if found:
        raise ValueError(f"Windows build script references omitted tests: {found}")
    required = ("swift build", "stage-windows-portable.ps1", "build-windows-installer.ps1")
    missing = [value for value in required if value not in source]
    if missing:
        raise ValueError(f"Windows production build actions are missing: {missing}")
    if re.search(r"(?m)^\s*\{\s*$", source):
        raise ValueError("Windows build script contains a standalone script block")
    required_lines = (
        r"(?m)^  \$portableDir = Join-Path \$resolvedOutDir \$architecture$",
        r"(?m)^  & \$stageScript @stageArguments$",
    )
    if any(not re.search(pattern, source) for pattern in required_lines):
        raise ValueError("Portable staging is not unconditional within the production try block")
