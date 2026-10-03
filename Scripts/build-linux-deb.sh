#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload="$1"
output="$2"
architecture="$3"
case "$architecture" in
  x64) debian_architecture=amd64 ;;
  arm64) debian_architecture=arm64 ;;
  *) echo "Architecture must be x64 or arm64." >&2; exit 1 ;;
esac
version="$(awk -F= '/^MARKETING_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2}' "$root/Config/Base.xcconfig")"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/DEBIAN" "$temporary/opt/codex-bridge" \
  "$temporary/usr/share/applications" "$temporary/usr/share/icons/hicolor/512x512/apps"
cp -a "$payload/." "$temporary/opt/codex-bridge/"
install -m 644 "$root/Linux/org.codexbridge.CodexBridge.desktop" "$temporary/usr/share/applications/"
install -m 644 "$root/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png" \
  "$temporary/usr/share/icons/hicolor/512x512/apps/org.codexbridge.CodexBridge.png"
cat > "$temporary/DEBIAN/control" <<EOF
Package: codex-bridge
Version: $version
Architecture: $debian_architecture
Maintainer: Codex Bridge contributors
Section: devel
Priority: optional
Depends: libc6 (>= 2.39), libgtk-3-0t64, libwebkit2gtk-4.1-0, libsqlite3-0, libsecret-tools, gnome-keyring, bubblewrap, libcurl4t64, libicu74, libxml2, libatomic1
Description: Local Agent workbench and MCP gateway
 Shared desktop workspace for local coding agents and MCP clients.
EOF
filename="CodexBridge-Linux-$architecture-$version.deb"
dpkg-deb --root-owner-group --build "$temporary" "$output/$filename"
(cd "$output" && sha256sum "$filename" > "$filename.sha256")
