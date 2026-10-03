import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


UUID = re.compile(r"\b[A-Z0-9]{24}\b")


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


def _matching(text, opening):
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
    raise ValueError(f"Unclosed PBX object at offset {opening}")


@dataclass
class PBXObject:
    identifier: str
    start: int
    brace: int
    close: int
    body: str
    isa: str


def _objects(source):
    object_start = source.find("objects = {")
    if object_start < 0:
        raise ValueError("Xcode project has no objects section")
    end = source.find("\n\t};", object_start)
    if end < 0:
        raise ValueError("Xcode project objects section is not closed")
    section = source[object_start:end]
    result = {}
    cursor = section.find("{", 0) + 1
    header = re.compile(r"([A-Z0-9]{24})(?:\s*/\*.*?\*/)?\s*=\s*\{")
    while cursor < len(section):
        if section[cursor].isspace():
            cursor += 1
            continue
        skipped = _skip(section, cursor)
        if skipped != cursor:
            cursor = skipped
            continue
        match = header.match(section, cursor)
        if not match:
            if section[cursor:].strip():
                raise ValueError("Unexpected content in Xcode project objects section")
            break
        brace = object_start + match.end() - 1
        close = _matching(source, brace)
        body = source[brace + 1 : close - 1]
        isa_match = re.search(r"\bisa\s*=\s*(\w+)\s*;", body)
        if not isa_match:
            raise ValueError(f"PBX object has no isa: {match.group(1)}")
        result[match.group(1)] = PBXObject(
            match.group(1), object_start + match.start(1), brace, close, body, isa_match.group(1)
        )
        cursor = close - object_start
        if cursor < len(section) and section[cursor] == ";":
            cursor += 1
    return result


def _property(body, name):
    match = re.search(rf"\b{re.escape(name)}\s*=\s*(\"[^\"]*\"|[^;]+);", body)
    return match.group(1).strip().strip('"') if match else ""


def _is_test_target(item):
    product_type = _property(item.body, "productType")
    name = _property(item.body, "name")
    return "unit-test" in product_type or "ui-testing" in product_type or name.endswith("Tests")


def test_target_names(path):
    return {
        _property(item.body, "name")
        for item in _objects(Path(path).read_text()).values()
        if item.isa == "PBXNativeTarget" and _is_test_target(item)
    }


def _is_test_group(item):
    return item.isa in {"PBXGroup", "PBXFileSystemSynchronizedRootGroup"} and (
        _property(item.body, "path").lower() in {"uitests", "tests"}
        or _property(item.body, "name").lower() in {"uitests", "tests"}
    )


def _is_test_file(item):
    path = _property(item.body, "path").lower()
    return item.isa == "PBXFileReference" and (
        path.endswith(".xctest") or "uitest" in path or path.endswith("tests.swift")
    )


def _candidate_ids(objects, roots):
    allowed = {
        "PBXBuildFile", "PBXContainerItemProxy", "PBXTargetDependency", "XCBuildConfiguration",
        "XCConfigurationList", "PBXCopyFilesBuildPhase", "PBXFrameworksBuildPhase",
        "PBXHeadersBuildPhase", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
        "PBXShellScriptBuildPhase",
    }
    candidates = set(roots)
    pending = list(roots)
    while pending:
        item = objects[pending.pop()]
        for reference in UUID.findall(item.body):
            child = objects.get(reference)
            if not child or reference in candidates:
                continue
            if child.isa in allowed or _is_test_group(child) or _is_test_file(child):
                candidates.add(reference)
                pending.append(reference)
    return candidates


def _remove_target_attribute(source, target_ids):
    for target_id in target_ids:
        pattern = re.compile(rf"(?m)^[ \t]*{target_id}\s*=\s*\{{")
        match = pattern.search(source)
        if match:
            end = _matching(source, source.find("{", match.start()))
            right = end
            if right < len(source) and source[right] == ";":
                right += 1
            if right < len(source) and source[right] == ",":
                right += 1
            if right < len(source) and source[right] == "\n":
                right += 1
            source = source[: match.start()] + source[right:]
    return source


def _remove_reference_lines(body, identifiers):
    lines = []
    for line in body.splitlines(keepends=True):
        refs = set(UUID.findall(line))
        if refs & identifiers and re.fullmatch(
            r"\s*(?:[A-Z0-9]{24})(?:\s*/\*.*?\*/)?\s*,?\s*\n?", line
        ):
            continue
        lines.append(line)
    return "".join(lines)


def transform_project(path):
    path = Path(path)
    source = path.read_text()
    objects = _objects(source)
    test_targets = {
        identifier
        for identifier, item in objects.items()
        if item.isa == "PBXNativeTarget" and _is_test_target(item)
    }
    if not test_targets:
        return
    forced = set(test_targets)
    forced.update(identifier for identifier, item in objects.items() if _is_test_group(item))
    forced.update(identifier for identifier, item in objects.items() if _is_test_file(item))
    candidates = _candidate_ids(objects, forced)
    for identifier in forced:
        if identifier not in candidates:
            candidates.add(identifier)
    reachable = set()
    pending = [identifier for identifier in objects if identifier not in candidates]
    while pending:
        identifier = pending.pop()
        for reference in UUID.findall(objects[identifier].body):
            if reference in forced:
                continue
            if reference in candidates and reference not in reachable:
                reachable.add(reference)
                pending.append(reference)
            elif reference in objects and reference not in candidates and reference not in reachable:
                reachable.add(reference)
                pending.append(reference)
    removed = candidates - reachable

    replacements = []
    for identifier, item in objects.items():
        if identifier in removed:
            left, right = item.start, item.close
            if right < len(source) and source[right] == ";":
                right += 1
            if right < len(source) and source[right] == "\n":
                right += 1
            replacements.append((left, right, ""))
        elif identifier not in removed:
            body = _remove_reference_lines(item.body, forced)
            if body != item.body:
                replacements.append((item.brace + 1, item.close - 1, body))
    for left, right, replacement in sorted(replacements, reverse=True):
        source = source[:left] + replacement + source[right:]
    source = _remove_target_attribute(source, test_targets)
    path.write_text(source)


def transform_scheme(path, test_names):
    path = Path(path)
    tree = ET.parse(path)
    root = tree.getroot()
    for parent in root.iter():
        for child in list(parent):
            if child.tag == "TestAction":
                parent.remove(child)
            elif child.tag == "BuildActionEntry" and any(
                reference.get("BlueprintName", "") in test_names
                for reference in child.iter("BuildableReference")
            ):
                parent.remove(child)
    ET.indent(tree, space="   ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def verify_project(path, scheme_path):
    objects = _objects(Path(path).read_text())
    tests = [
        item for item in objects.values()
        if item.isa == "PBXNativeTarget" and _is_test_target(item)
    ]
    if tests:
        raise ValueError("Xcode project still declares a test target")
    identifiers = set(objects)
    dangling = set()
    for item in objects.values():
        for reference in UUID.findall(item.body):
            if reference not in identifiers and reference != "000000000000000000000000":
                dangling.add(reference)
    if dangling:
        raise ValueError(f"Xcode project contains dangling object references: {sorted(dangling)}")
    scheme = Path(scheme_path).read_text()
    if "TestAction" in scheme or "UITests" in scheme or "Tests.xctest" in scheme:
        raise ValueError("Xcode scheme still references tests")
