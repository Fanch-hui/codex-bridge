#!/bin/zsh
set -euo pipefail
umask 077

readonly resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
[[ -d "${resources_directory}" && ! -L "${resources_directory}" ]] || {
  print -u2 "App resources directory is missing or unsafe."
  exit 66
}
readonly resource_specs=(
  "BridgeCore_BridgeDeepSeekHarnessACP.bundle:cordis.yml"
  "BridgeCore_BridgePiRPC.bundle:PiBridgeExtension/index.mjs"
  "BridgeCore_BridgeQoderSDK.bundle:QoderHost/index.mjs"
)
temporary_root="$(/usr/bin/mktemp -d "${TARGET_BUILD_DIR}/.codex-bridge-service-resources.XXXXXX")"
readonly temporary_root

cleanup() {
  [[ -d "${temporary_root}" ]] || return
  /bin/rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for spec in "${resource_specs[@]}"; do
  bundle_name="${spec%%:*}"
  entry="${spec#*:}"
  requested_source="${BUILT_PRODUCTS_DIR}/${bundle_name}"
  source_bundle="${requested_source:A}"
  destination_bundle="${resources_directory}/${bundle_name}"
  staged_bundle="${temporary_root}/${bundle_name}"
  [[ -d "${source_bundle}" && ! -L "${source_bundle}" &&
    -f "${source_bundle}/Contents/Resources/${entry}" &&
    ! -L "${source_bundle}/Contents/Resources/${entry}" ]] || {
    print -u2 "Agent resource bundle is missing or unsafe: ${bundle_name}"
    exit 66
  }
  [[ ! -L "${destination_bundle}" ]] || {
    print -u2 "Agent resource destination is unsafe: ${bundle_name}"
    exit 65
  }
  /usr/bin/ditto "${source_bundle}" "${staged_bundle}"
  [[ -f "${staged_bundle}/Contents/Resources/${entry}" ]] || {
    print -u2 "Staged Agent resources are incomplete: ${bundle_name}"
    exit 66
  }
  if [[ "${bundle_name}" != "BridgeCore_BridgeDeepSeekHarnessACP.bundle" ]]; then
    module_name="${bundle_name#BridgeCore_}"
    module_name="${module_name%.bundle}"
    source_resources="${0:A:h:h}/Packages/BridgeCore/Sources/${module_name}/Resources"
    for source_file in "${source_resources}"/**/*(.N); do
      relative_file="${source_file#${source_resources}/}"
      packaged_file="${staged_bundle}/Contents/Resources/${relative_file}"
      [[ -f "${packaged_file}" && ! -L "${packaged_file}" ]] &&
        /usr/bin/cmp -s "${source_file}" "${packaged_file}" || {
        print -u2 "Packaged Agent resource differs from its source: ${relative_file}"
        exit 65
      }
    done
  fi
  if [[ -e "${destination_bundle}" ]]; then
    /bin/rm -rf -- "${destination_bundle}"
  fi
  /bin/mv "${staged_bundle}" "${destination_bundle}"
done
print "Staged Agent resources for the embedded Service."
