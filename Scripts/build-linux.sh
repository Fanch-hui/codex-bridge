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

mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
runtime_temporary="$(mktemp -d "$output/.embedded-dsh.XXXXXXXX")"
trap 'rm -rf -- "$runtime_temporary"' EXIT
embedded_runtime="$runtime_temporary/runtime"
node "$root/Scripts/build-embedded-dsh-runtime.mjs" \
  --platform linux --arch "$architecture" --output "$embedded_runtime"
node "$root/Scripts/verify-embedded-dsh-runtime.mjs" "$embedded_runtime" linux "$architecture"

pkg-config --exists webkit2gtk-4.1
arguments=(--package-path "$root/Packages/BridgeCore" --build-system swiftbuild
  -c "$configuration" -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
  -Xlinker -rpath -Xlinker '$ORIGIN/lib')
swift build "${arguments[@]}" --product codex-bridge-service
swift build "${arguments[@]}" --product codex-bridge-linux-app
binary_directory="$(swift build "${arguments[@]}" --show-bin-path | tail -1)"
"$root/Scripts/stage-linux-portable.sh" "$binary_directory" "$output" "$architecture" "$embedded_runtime"
"$root/Scripts/build-linux-deb.sh" "$output/$architecture" "$output" "$architecture"
