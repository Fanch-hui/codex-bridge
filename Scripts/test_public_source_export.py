import subprocess
import tempfile
import unittest
from pathlib import Path

from public_source_export import export_source, verify_source
from public_source_policy import is_public_path
from public_source_swift import (
    _manifest_entries,
    transform_manifest,
)
from public_source_manifest_verify import verify_manifests
from public_source_workflow import (
    transform_workflow,
    verify_mcp_registry_workflow,
    verify_workflow,
)
from public_source_windows import transform_windows_build_script, verify_windows_build_script
from public_source_xcode import (
    test_target_names,
    transform_project,
    transform_scheme,
    verify_project,
)


REPO = Path(__file__).resolve().parents[1]


class PublicSourceTransformTests(unittest.TestCase):
    def test_swift_manifests_keep_production_targets_and_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_manifests = {}
            for relative in ("Packages/BridgeCore/Package.swift", "Vendor/swift-sdk/Package.swift"):
                source_path = REPO / relative
                exported_path = root / relative
                exported_path.parent.mkdir(parents=True, exist_ok=True)
                exported_path.write_bytes(source_path.read_bytes())
                source_manifests[relative] = source_path.read_text()
                source_package_root = source_path.parent
                for directory in ("Sources", "Windows"):
                    candidate = source_package_root / directory
                    if candidate.exists():
                        (exported_path.parent / directory).symlink_to(candidate, target_is_directory=True)
                transform_manifest(exported_path)
            verify_manifests(root, source_manifests)
            bridge_manifest = (root / "Packages/BridgeCore/Package.swift").read_text()
            targets = _manifest_entries(bridge_manifest, "targets", "macOSOnlyTargets")
            shell = next(values for kind, values in targets if values.get("name") == '"BridgeServiceAppShell"')
            self.assertIn('"BridgeAgentCore"', shell["dependencies"])
            self.assertNotIn("CodexRPCFixture", bridge_manifest)
            self.assertNotIn("BridgeTunnelFixture", bridge_manifest)
            sdk_manifest = (root / "Vendor/swift-sdk/Package.swift").read_text()
            self.assertIn(".library(\n            name: \"MCP\"", sdk_manifest)
            self.assertNotIn("MCPConformance", sdk_manifest)

    def test_xcode_test_objects_and_scheme_are_removed_without_dangling_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project.pbxproj"
            scheme = root / "CodexBridge.xcscheme"
            project.write_bytes((REPO / "CodexBridge.xcodeproj/project.pbxproj").read_bytes())
            scheme.write_bytes(
                (REPO / "CodexBridge.xcodeproj/xcshareddata/xcschemes/CodexBridge.xcscheme").read_bytes()
            )
            names = test_target_names(project)
            self.assertIn("CodexBridgeUITests", names)
            transform_project(project)
            transform_scheme(scheme, names)
            verify_project(project, scheme)
            self.assertNotIn("CodexBridgeUITests", project.read_text())

    def test_windows_workflow_keeps_production_packaging_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            workflow = Path(temporary) / "windows.yml"
            workflow.write_bytes((REPO / ".github/workflows/windows.yml").read_bytes())
            transform_workflow(workflow)
            verify_workflow(workflow)
            content = workflow.read_text()
            self.assertNotIn("Smoke", content)
            self.assertIn("Upload Windows portable ZIP", content)
            self.assertIn("Upload Windows EXE installer", content)

    def test_windows_build_script_keeps_build_and_package_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "build-windows.ps1"
            script.write_bytes((REPO / "Scripts/build-windows.ps1").read_bytes())
            transform_windows_build_script(script)
            verify_windows_build_script(script)
            content = script.read_text()
            self.assertNotIn("-Test", content)
            self.assertIn("build-windows-installer.ps1", content)
            self.assertNotRegex(content, r"(?m)^\s*\{\s*$")
            self.assertRegex(content, r"(?m)^  \$portableDir = Join-Path \$resolvedOutDir \$architecture$")
            self.assertRegex(content, r"(?m)^  & \$stageScript @stageArguments$")
            self.assertLess(content.index("Push-Location $packagePath\ntry {"), content.index("  $portableDir"))
            self.assertLess(content.index("  $portableDir"), content.index("} finally {"))

    def test_mcp_registry_workflow_uses_release_metadata(self):
        verify_mcp_registry_workflow(REPO / ".github/workflows/mcp-registry.yml", REPO)

    def test_public_path_policy_excludes_private_trees(self):
        for path in (
            "Packages/BridgeCore/Tests/Example.swift",
            "Packages/BridgeCore/Sources/CodexRPCFixture/main.swift",
            "Prototypes/App/main.swift",
            "Schemas/server.json",
            "docs/Code-Review.md",
            "AGENTS.md",
            "server.json",
        ):
            self.assertFalse(is_public_path(path), path)
        for path in (
            "Packages/BridgeCore/Sources/BridgeAgentCore/AgentProvider.swift",
            "Packages/BridgeCore/Package.swift",
            "Scripts/export-public-source.py",
            "Scripts/mcpb-release-metadata.mjs",
            "Integrations/MCPB/manifest.json",
            ".gitattributes",
        ):
            self.assertTrue(is_public_path(path), path)


class PublicSourceExportTests(unittest.TestCase):
    def test_export_uses_git_blob_preserves_mode_and_requires_new_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repository"
            root.mkdir()
            (root / "Scripts").mkdir()
            (root / ".github/workflows").mkdir(parents=True)
            (root / "Integrations/MCPB").mkdir(parents=True)
            (root / "Prototypes").mkdir()
            (root / "Schemas").mkdir()
            (root / ".gitattributes").write_bytes(b"runtime/** -text\n")
            (root / ".github/workflows/mcp-registry.yml").write_text(
                'gh release download --pattern server.json\n'
                'node Scripts/verify-mcpb-release.mjs "$RUNNER_TEMP/mcp-package/server.json"\n'
            )
            (root / "Integrations/MCPB/manifest.json").write_text("{}")
            source_file = root / "Scripts/runtime.py"
            source_file.write_bytes(b"print('tracked')\n")
            source_file.chmod(0o755)
            for name in (
                "build-mcpb.mjs", "mcpb-release-metadata.mjs", "verify-mcpb-release.mjs",
                "test-mcpb-release.mjs",
            ):
                (root / "Scripts" / name).write_text(name)
            (root / "server.json").write_text("private snapshot")
            (root / "Scripts/test_private.py").write_text("private")
            (root / "Prototypes/example.swift").write_text("private")
            (root / "Schemas/output.json").write_text("private")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(
                ["git", "-C", str(root), "-c", "user.name=Export Test", "-c",
                 "user.email=export@example.invalid", "commit", "-qm", "fixture"],
                check=True,
            )
            source_file.write_bytes(b"untracked edit\n")
            output = root / ".build/public"
            commit, count = export_source(root, "HEAD", output)
            self.assertEqual(count, 7)
            self.assertEqual(source_file.read_bytes(), b"untracked edit\n")
            self.assertEqual((output / "Scripts/runtime.py").read_bytes(), b"print('tracked')\n")
            self.assertEqual(output.joinpath("Scripts/runtime.py").stat().st_mode & 0o777, 0o755)
            self.assertTrue((output / ".gitattributes").is_file())
            self.assertTrue((output / ".github/workflows/mcp-registry.yml").is_file())
            self.assertTrue((output / "Scripts/mcpb-release-metadata.mjs").is_file())
            self.assertTrue((output / "Scripts/verify-mcpb-release.mjs").is_file())
            self.assertFalse((output / "Prototypes").exists())
            self.assertFalse((output / "Scripts/test_private.py").exists())
            self.assertFalse((output / "Scripts/test-mcpb-release.mjs").exists())
            self.assertFalse((output / "server.json").exists())
            self.assertEqual(verify_source(root, commit, output), 7)
            with self.assertRaises(FileExistsError):
                export_source(root, "HEAD", output)


if __name__ == "__main__":
    unittest.main()
