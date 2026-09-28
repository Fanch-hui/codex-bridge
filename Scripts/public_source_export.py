import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from public_source_swift import transform_manifest
from public_source_manifest_verify import verify_manifests
from public_source_xcode import (
    test_target_names,
    transform_project,
    transform_scheme,
    verify_project,
)
from public_source_workflow import (
    transform_workflow,
    verify_mcp_registry_workflow,
    verify_workflow,
)
from public_source_windows import transform_windows_build_script, verify_windows_build_script
from public_source_policy import is_public_path


TRANSFORMED_FILES = {
    "Packages/BridgeCore/Package.swift",
    "Vendor/swift-sdk/Package.swift",
    "CodexBridge.xcodeproj/project.pbxproj",
    "CodexBridge.xcodeproj/xcshareddata/xcschemes/CodexBridge.xcscheme",
    ".github/workflows/windows.yml",
    "Scripts/build-windows.ps1",
}
@dataclass(frozen=True)
class TreeEntry:
    mode: str
    object_id: str
    path: str


def _git(root, *arguments, binary=False):
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=not binary,
    )
    return result.stdout


def resolve_ref(root, ref):
    return _git(root, "rev-parse", "--verify", f"{ref}^{{commit}}").strip()


def tracked_tree(root, ref):
    raw = _git(root, "ls-tree", "-rz", "--full-tree", "-r", ref, binary=True)
    entries = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, encoded_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()
        if object_type != "blob":
            continue
        path = os.fsdecode(encoded_path)
        pure = PurePosixPath(path)
        if pure.is_absolute() or ".." in pure.parts or "\\" in path:
            raise ValueError(f"Unsafe path in tracked tree: {path!r}")
        entries.append(TreeEntry(mode, object_id, path))
    return entries


def _git_blobs(root, object_ids):
    unique = list(dict.fromkeys(object_ids))
    request = b"".join(f"{object_id}\n".encode("ascii") for object_id in unique)
    result = subprocess.run(
        ["git", "-C", str(root), "cat-file", "--batch"],
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    content = result.stdout
    blobs = {}
    offset = 0
    for object_id in unique:
        end = content.find(b"\n", offset)
        if end < 0:
            raise ValueError(f"Git returned an incomplete blob header for {object_id}")
        returned_id, object_type, size = content[offset:end].decode("ascii").split()
        if returned_id != object_id or object_type != "blob":
            raise ValueError(f"Git returned an unexpected object for {object_id}")
        start = end + 1
        blob_end = start + int(size)
        if blob_end >= len(content) or content[blob_end : blob_end + 1] != b"\n":
            raise ValueError(f"Git returned an incomplete blob for {object_id}")
        blobs[object_id] = content[start:blob_end]
        offset = blob_end + 1
    return blobs


def _write_entry(output, entry, source):
    destination = output.joinpath(*PurePosixPath(entry.path).parts)
    destination.parent.mkdir(parents=True, exist_ok=True)
    mode = int(entry.mode, 8)
    if mode == 0o120000:
        target = os.fsdecode(source)
        resolved_target = (destination.parent / target).resolve()
        if Path(target).is_absolute() or not resolved_target.is_relative_to(output.resolve()):
            raise ValueError(f"Unsafe tracked symlink: {entry.path} -> {target}")
        os.symlink(target, destination)
    else:
        destination.write_bytes(source)
        destination.chmod(mode & 0o777)


def _transform_export(output):
    package = output / "Packages/BridgeCore/Package.swift"
    sdk = output / "Vendor/swift-sdk/Package.swift"
    if package.is_file():
        transform_manifest(package)
    if sdk.is_file():
        transform_manifest(sdk)
    project = output / "CodexBridge.xcodeproj/project.pbxproj"
    scheme = output / "CodexBridge.xcodeproj/xcshareddata/xcschemes/CodexBridge.xcscheme"
    if project.is_file():
        tests = test_target_names(project)
        transform_project(project)
        if scheme.is_file():
            transform_scheme(scheme, tests)
    workflow = output / ".github/workflows/windows.yml"
    if workflow.is_file():
        transform_workflow(workflow)
    windows_builder = output / "Scripts/build-windows.ps1"
    if windows_builder.is_file():
        transform_windows_build_script(windows_builder)


def export_source(root, ref, output):
    root = Path(root).resolve()
    output = Path(output)
    if not output.is_absolute():
        output = root / output
    output = output.absolute()
    if os.path.lexists(output):
        raise FileExistsError(f"Output path already exists: {output}")
    commit = resolve_ref(root, ref)
    entries = [entry for entry in tracked_tree(root, commit) if is_public_path(entry.path)]
    blobs = _git_blobs(root, [entry.object_id for entry in entries])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir()
    try:
        for entry in entries:
            _write_entry(output, entry, blobs[entry.object_id])
        _transform_export(output)
        verify_source(root, commit, output)
    except Exception:
        shutil.rmtree(output)
        raise
    return commit, len(entries)


def _expected_entries(root, ref):
    return {entry.path: entry for entry in tracked_tree(root, ref) if is_public_path(entry.path)}


def _output_files(output):
    files = set()
    for path in output.rglob("*"):
        if path.is_file() or path.is_symlink():
            files.add(path.relative_to(output).as_posix())
    return files


def _check_exclusions(files):
    bad = [
        path for path in files
        if not is_public_path(path)
    ]
    if bad:
        raise ValueError(f"Excluded paths are present in export: {sorted(bad)[:20]}")


def _source_manifests(entries, blobs):
    values = {}
    for path, entry in entries.items():
        if path in {"Packages/BridgeCore/Package.swift", "Vendor/swift-sdk/Package.swift"}:
            values[path] = blobs[entry.object_id].decode("utf-8")
    return values


def verify_source(root, ref, output):
    root = Path(root).resolve()
    output = Path(output).resolve()
    if not output.is_dir():
        raise FileNotFoundError(f"Export directory does not exist: {output}")
    entries = _expected_entries(root, ref)
    blobs = _git_blobs(root, [entry.object_id for entry in entries.values()])
    actual = _output_files(output)
    expected = set(entries)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(f"Export file list differs (missing={missing[:12]}, extra={extra[:12]})")
    _check_exclusions(actual)
    for path, entry in entries.items():
        exported = output.joinpath(*PurePosixPath(path).parts)
        mode = int(entry.mode, 8)
        if mode == 0o120000:
            if not exported.is_symlink():
                raise ValueError(f"Tracked symlink mode changed: {path}")
        else:
            actual_mode = exported.stat().st_mode & 0o777
            if actual_mode != (mode & 0o777):
                raise ValueError(f"File mode changed: {path} ({actual_mode:o} != {mode:o})")
        if path not in TRANSFORMED_FILES:
            source = blobs[entry.object_id]
            actual_bytes = os.fsencode(os.readlink(exported)) if exported.is_symlink() else exported.read_bytes()
            if source != actual_bytes:
                raise ValueError(f"Production source differs from ref {ref}: {path}")
    verify_manifests(output, _source_manifests(entries, blobs))
    project = output / "CodexBridge.xcodeproj/project.pbxproj"
    scheme = output / "CodexBridge.xcodeproj/xcshareddata/xcschemes/CodexBridge.xcscheme"
    if project.is_file() and scheme.is_file():
        verify_project(project, scheme)
    workflow = output / ".github/workflows/windows.yml"
    if workflow.is_file():
        verify_workflow(workflow)
    registry_workflow = output / ".github/workflows/mcp-registry.yml"
    if registry_workflow.is_file():
        verify_mcp_registry_workflow(registry_workflow, output)
    windows_builder = output / "Scripts/build-windows.ps1"
    if windows_builder.is_file():
        verify_windows_build_script(windows_builder)
    return len(actual)
