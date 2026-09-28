from pathlib import PurePosixPath


ROOT_FILES = {
    ".gitattributes", ".gitignore", "CONTRIBUTING.md", "DESIGN.md", "LICENSE", "NOTICE",
    "PRIVACY.md", "README.md", "README_en.md", "SECURITY.md",
}
EXCLUDED_PARTS = {"tests", "uitests", "fixture", "fixtures", "prototypes", "schemas", "examples"}
PRIVATE_DOCUMENT_WORDS = {"review", "adjudication", "plan", "memory", "optimization", "handoff"}


def _is_private_document(path):
    name = PurePosixPath(path).name.lower()
    if PurePosixPath(path).suffix.lower() not in {".md", ".markdown", ".txt"}:
        return name == "agents.md"
    return any(word in name for word in PRIVATE_DOCUMENT_WORDS) or name == "agents.md"


def is_public_path(path):
    pure = PurePosixPath(path)
    parts = pure.parts
    lowered = tuple(part.lower() for part in parts)
    if any(
        part in EXCLUDED_PARTS or part.endswith("fixture") or part.endswith("fixtures")
        for part in lowered
    ):
        return False
    if any(part in {".git", ".build", "xcuserdata", "__pycache__"} for part in lowered):
        return False
    if _is_private_document(path):
        return False
    if parts[0] == "CodexBridge.xcodeproj" and "test" in pure.name.lower():
        return False
    if path == "server.json":
        return False
    if parts[0] in ROOT_FILES:
        return True
    if parts[0] in {"App", "Service", "Config", "Windows", "CodexBridge.xcodeproj"}:
        return True
    if parts[0] == "docs":
        return pure.suffix.lower() in {".md", ".png", ".jpg", ".jpeg", ".svg", ".webp", ".gif"}
    if parts[0] == "Scripts":
        return not (
            pure.name.lower().startswith("test-")
            or pure.name.lower().startswith("test_")
            or pure.name == "desktop-ui-test-support.cjs"
            or pure.name == "generate-codex-schemas.sh"
            or pure.name in {"verify-stage0.sh", "verify-mcp-inspector.sh"}
        )
    if parts[0] == "Packages":
        if path in {"Packages/BridgeCore/Package.swift", "Packages/BridgeCore/Package.resolved"}:
            return True
        return path.startswith(("Packages/BridgeCore/Sources/", "Packages/BridgeCore/Windows/"))
    if parts[0] == "Vendor":
        if path.startswith("Vendor/swift-sdk/Sources/MCP/"):
            return True
        return (
            len(parts) == 3
            and parts[:2] == ("Vendor", "swift-sdk")
            and pure.name in {
                "Package.swift", "Package@swift-6.0.swift", "Package.resolved", "LICENSE", "NOTICE"
            }
        )
    if parts[:2] == ("Integrations", "MCPB"):
        return True
    if parts[:2] == (".github", "workflows"):
        return pure.name in {"windows.yml", "mcp-registry.yml"}
    if parts[:2] == (".github", "scripts"):
        return not pure.name.lower().startswith("test-")
    return False
