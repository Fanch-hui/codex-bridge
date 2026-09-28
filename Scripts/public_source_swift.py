import re
from pathlib import Path


def _skip(text, index):
    if text.startswith("//", index):
        end = text.find("\n", index)
        return len(text) if end < 0 else end
    if text.startswith("/*", index):
        depth = 1
        index += 2
        while index < len(text) and depth:
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        return index
    if text[index] == '"':
        index += 1
        while index < len(text):
            if text[index] == "\\":
                index += 2
            elif text[index] == '"':
                return index + 1
            else:
                index += 1
        return index
    return index


def _matching(text, opening, left, right):
    depth = 0
    index = opening
    while index < len(text):
        skipped = _skip(text, index)
        if skipped != index:
            index = skipped
            continue
        char = text[index]
        if char == left:
            depth += 1
        elif char == right:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError(f"Unclosed Swift delimiter at offset {opening}")


def _code_mask(text):
    mask = bytearray(b"\1") * len(text)
    index = 0
    while index < len(text):
        skipped = _skip(text, index)
        if skipped != index:
            mask[index:skipped] = b"\0" * (skipped - index)
            index = skipped
        else:
            index += 1
    return mask


def _split_entries(text):
    entries = []
    starts = 0
    stack = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    index = 0
    while index < len(text):
        skipped = _skip(text, index)
        if skipped != index:
            index = skipped
            continue
        char = text[index]
        if char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
        elif char == "," and not stack:
            if text[starts:index].strip():
                entries.append(text[starts:index])
            starts = index + 1
        index += 1
    if text[starts:].strip():
        entries.append(text[starts:])
    return entries


def _top_level_colon(entry):
    stack = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    index = 0
    while index < len(entry):
        skipped = _skip(entry, index)
        if skipped != index:
            index = skipped
            continue
        char = entry[index]
        if char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
        elif char == ":" and not stack:
            return index
        index += 1
    return -1


def _named_arguments(text):
    result = {}
    for entry in _split_entries(text):
        colon = _top_level_colon(entry)
        if colon >= 0:
            result[entry[:colon].strip()] = entry[colon + 1 :].strip()
    return result


def _call_entries(array_text):
    opening = array_text.find("[")
    if opening < 0:
        return []
    end = _matching(array_text, opening, "[", "]") - 1
    result = []
    for entry in _split_entries(array_text[opening + 1 : end]):
        match = re.match(r"\s*\.(\w+)\s*\(", entry)
        if not match:
            continue
        call_open = entry.find("(", match.start())
        call_end = _matching(entry, call_open, "(", ")")
        result.append((match.group(1), _named_arguments(entry[call_open + 1 : call_end - 1])))
    return result


def _package_arguments(source):
    match = re.search(r"\bPackage\s*\(", source)
    if not match:
        raise ValueError("Package.swift has no Package initializer")
    opening = source.find("(", match.start())
    end = _matching(source, opening, "(", ")") - 1
    return _named_arguments(source[opening + 1 : end])


def _array_variables(source, name):
    pattern = re.compile(rf"\b{re.escape(name)}\s*(?::\s*\[[^]]+\])?\s*=\s*\[")
    for match in pattern.finditer(source):
        opening = source.find("[", match.start(), match.end())
        end = _matching(source, opening, "[", "]")
        yield source[opening:end]


def _manifest_entries(source, field, variable):
    package = _package_arguments(source)
    arrays = [package[field]] if field in package else []
    arrays.extend(_array_variables(source, variable))
    entries = []
    for array in arrays:
        entries.extend(_call_entries(array))
    return entries


def _is_fixture_target(name, path):
    lowered = f"{name} {path}".lower().replace("\\", "/")
    return "fixture" in lowered or "conformance" in lowered or "inspector" in lowered


def _remove_calls(source, kinds, predicate):
    pattern = re.compile(r"\.(" + "|".join(map(re.escape, kinds)) + r")\s*\(")
    mask = _code_mask(source)
    spans = []
    for match in pattern.finditer(source):
        if not mask[match.start()]:
            continue
        opening = source.find("(", match.start(), match.end())
        end = _matching(source, opening, "(", ")")
        if not predicate(match.group(1), _named_arguments(source[opening + 1 : end - 1])):
            continue
        left, right = match.start(), end
        while right < len(source) and source[right].isspace():
            right += 1
        if right < len(source) and source[right] == ",":
            right += 1
        else:
            previous = left - 1
            while previous >= 0 and source[previous].isspace():
                previous -= 1
            if previous >= 0 and source[previous] == ",":
                left = previous
        spans.append((left, right))
    merged = []
    for left, right in sorted(spans):
        if merged and left <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], right))
        else:
            merged.append((left, right))
    for left, right in reversed(merged):
        source = source[:left] + source[right:]
    return source


def _remove_array_assignment(source, expression):
    pattern = expression + r"\s*\["
    while match := re.search(pattern, source):
        opening = source.rfind("[", match.start(), match.end())
        end = _matching(source, opening, "[", "]")
        left = source.rfind("\n", 0, match.start()) + 1
        right = source.find("\n", end)
        source = source[:left] + ("" if right < 0 else source[right + 1 :])
    return source


def transform_manifest(path):
    source = Path(path).read_text()
    declarations = _manifest_entries(source, "targets", "macOSOnlyTargets")
    targets_to_remove = {
        values.get("name", "").strip('"')
        for kind, values in declarations
        if kind == "testTarget"
        or _is_fixture_target(values.get("name", ""), values.get("path", ""))
    }

    source = _remove_array_assignment(source, r"var\s+testTargets\s*:\s*\[Target\]\s*=")
    source = _remove_array_assignment(source, r"testTargets\s*\+=")
    source = source.replace(" + testTargets", "")
    source = _remove_calls(source, ("testTarget",), lambda _kind, _args: True)
    source = _remove_calls(
        source,
        ("target", "executableTarget"),
        lambda _kind, args: _is_fixture_target(
            args.get("name", "").strip('"'), args.get("path", "").strip('"')
        )
        or args.get("name", "").strip('"') in targets_to_remove,
    )
    source = _remove_calls(
        source,
        ("library", "executable"),
        lambda _kind, args: any(
            name in targets_to_remove
            for name in re.findall(r'"([^"]+)"', args.get("targets", ""))
        )
        or _is_fixture_target(args.get("name", "").strip('"'), ""),
    )
    Path(path).write_text(source)
