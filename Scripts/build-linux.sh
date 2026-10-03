#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
output="${1:-$root/.build/linux-dist}"
case "$(uname -m)" in
  x86_64) architecture=x64 ;;
  aarch64) architecture=arm64 ;;
  *) echo "Unsupported Linux architecture." >&2; exit 1 ;;
esac

pkg-config --exists webkit2gtk-4.1
arguments=(--package-path "$root/Packages/BridgeCore" --build-system swiftbuild
  -c "$configuration" -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
  -Xlinker -rpath -Xlinker '$ORIGIN/lib')
swift build "${arguments[@]}" --product codex-bridge-service
swift build "${arguments[@]}" --product codex-bridge-linux-app
binary_directory="$(swift build "${arguments[@]}" --show-bin-path | tail -1)"
"$root/Scripts/stage-linux-portable.sh" "$binary_directory" "$output" "$architecture"
"$root/Scripts/build-linux-deb.sh" "$output/$architecture" "$output" "$architecture"
