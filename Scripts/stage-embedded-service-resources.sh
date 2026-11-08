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
  "BridgeCore_BridgeClaudeSDK.bundle:ClaudeHost/index.mjs"
  "BridgeCore_BridgeDeepSeekHarnessDesktop.bundle:DSHDesktopConnector/index.mjs"
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

architectures=(${(z)ARCHS})
(( ${#architectures} == 1 )) || {
  print -u2 "The embedded DSH runtime requires one target architecture."
  exit 64
}
case "${architectures[1]}" in
  arm64) runtime_architecture=arm64 ;;
  x86_64) runtime_architecture=x64 ;;
  *) print -u2 "Unsupported embedded DSH architecture."; exit 64 ;;
esac
readonly runtime_source="${EMBEDDED_DSH_RUNTIME_DIRECTORY:-${SRCROOT}/.build/embedded-dsh/darwin-${runtime_architecture}}"
readonly runtime_destination="${resources_directory}/EmbeddedDSH"
readonly runtime_verifier="${SRCROOT}/Scripts/verify-embedded-dsh-runtime.mjs"
[[ -d "${runtime_source}" && ! -L "${runtime_source}" && ! -L "${runtime_destination}" ]] || {
  print -u2 "The embedded DSH runtime for ${runtime_architecture} is missing or unsafe."
  exit 66
}
node "${runtime_verifier}" "${runtime_source}" darwin "${runtime_architecture}"
/usr/bin/ditto "${runtime_source}" "${temporary_root}/EmbeddedDSH"
node "${runtime_verifier}" "${temporary_root}/EmbeddedDSH" darwin "${runtime_architecture}"
if [[ -e "${runtime_destination}" ]]; then
  /bin/rm -rf -- "${runtime_destination}"
fi
/bin/mv "${temporary_root}/EmbeddedDSH" "${runtime_destination}"
print "Staged Agent resources for the embedded Service."
