import re
from pathlib import Path

from public_source_swift import (
    _is_fixture_target,
    _manifest_entries,
    _package_arguments,
    _matching,
    _split_entries,
)


def _array_value(value):
    opening = value.find("[")
    if opening < 0:
        return "[]"
    end = _matching(value, opening, "[", "]")
    return value[opening + 1 : end - 1]


def verify_manifests(root, source_manifests=None):
    root = Path(root)
    manifests = [
        root / "Packages/BridgeCore/Package.swift",
        root / "Vendor/swift-sdk/Package.swift",
        root / "Vendor/swift-sdk/Package@swift-6.0.swift",
    ]
    target_kinds = {"target", "executableTarget", "systemLibrary", "binaryTarget", "plugin"}
    for manifest in manifests:
        if not manifest.is_file():
            continue
        package_root = manifest.parent
        source = manifest.read_text()
        if ".testTarget(" in source or "testTargets" in source:
            raise ValueError(f"Test target remains in {manifest.relative_to(root)}")
        declarations = _manifest_entries(source, "targets", "macOSOnlyTargets")
        target_names = {
            values.get("name", "").strip('"')
            for kind, values in declarations
            if kind in target_kinds
        }
        for kind, values in declarations:
            if kind not in target_kinds:
                continue
            name = values.get("name", "").strip('"')
            target_path = values.get("path", f'"Sources/{name}"').strip().strip('"')
            if not name or _is_fixture_target(name, target_path):
                raise ValueError(f"Excluded target remains in {manifest.relative_to(root)}: {name}")
            for entry in _split_entries(_array_value(values.get("dependencies", ""))):
                target = entry.strip()
                if target.startswith('"'):
                    dependency = target[1:-1]
                    if dependency not in target_names:
                        raise ValueError(f"Dangling target dependency {dependency} in {manifest}")
                elif target.startswith(".target"):
                    match = re.search(r'name\s*:\s*"([^"]+)"', target)
                    if match and match.group(1) not in target_names:
                        raise ValueError(f"Dangling target dependency {match.group(1)} in {manifest}")
            if not (package_root / target_path).is_dir():
                raise ValueError(f"Target path is missing: {manifest.relative_to(root)}:{target_path}")
        products = _manifest_entries(source, "products", "macOSOnlyProducts")
        for _kind, values in products:
            names = re.findall(r'"([^"]+)"', values.get("targets", ""))
            missing = sorted(set(names) - target_names)
            if missing:
                raise ValueError(f"Product references missing target(s) in {manifest}: {missing}")
        if source_manifests is not None:
            relative = manifest.relative_to(root).as_posix()
            original = source_manifests.get(relative)
            if original is None:
                raise ValueError(f"Source manifest was not supplied for {relative}")
            if _package_arguments(original).get("dependencies") != _package_arguments(source).get("dependencies"):
                raise ValueError(f"External package dependencies changed in {manifest}")
