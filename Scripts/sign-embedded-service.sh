#!/bin/zsh
set -euo pipefail

readonly service_path="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/CodexBridgeService"
readonly deepseek_bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BridgeCore_BridgeDeepSeekHarnessACP.bundle"
readonly deepseek_template="${deepseek_bundle}/Contents/Resources/cordis.yml"
readonly embedded_dsh="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/EmbeddedDSH"

[[ -f "${service_path}" && -x "${service_path}" && ! -L "${service_path}" ]] || {
  print -u2 "Embedded CodexBridgeService is missing or unsafe."
  exit 66
}
[[ -d "${deepseek_bundle}" && ! -L "${deepseek_bundle}" && \
  -f "${deepseek_template}" && ! -L "${deepseek_template}" ]] || {
  print -u2 "Embedded DeepSeek Harness resources are missing or unsafe."
  exit 66
}

for spec in "BridgeCore_BridgeMCP.bundle:FileTransfer/index.html" \
  "BridgeCore_BridgePiRPC.bundle:PiBridgeExtension/index.mjs" \
  "BridgeCore_BridgeQoderSDK.bundle:QoderHost/index.mjs" \
  "BridgeCore_BridgeClaudeSDK.bundle:ClaudeHost/index.mjs" \
  "BridgeCore_BridgeDeepSeekHarnessDesktop.bundle:DSHDesktopConnector/index.mjs"; do
  bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/${spec%%:*}"
  entry="${bundle}/Contents/Resources/${spec#*:}"
  [[ -d "${bundle}" && ! -L "${bundle}" && -f "${entry}" && ! -L "${entry}" ]] || {
    print -u2 "Embedded Agent resources are missing or unsafe: ${spec%%:*}"
    exit 66
  }
done

for architecture in ${(z)ARCHS}; do
  /usr/bin/lipo "${service_path}" -verify_arch "${architecture}"
done

architectures=(${(z)ARCHS})
(( ${#architectures} == 1 )) || { print -u2 "Embedded DSH requires one architecture."; exit 64; }
case "${architectures[1]}" in
  arm64) runtime_architecture=arm64; node_entitlements="${SRCROOT}/Config/EmbeddedDSHNode.entitlements" ;;
  x86_64) runtime_architecture=x64; node_entitlements="${SRCROOT}/Config/EmbeddedDSHNodeIntel.entitlements" ;;
  *) print -u2 "Unsupported embedded DSH architecture."; exit 64 ;;
esac
node "${SRCROOT}/Scripts/verify-embedded-dsh-runtime.mjs" "${embedded_dsh}" darwin "${runtime_architecture}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  dsh_arguments=("${embedded_dsh}" "${identity}" "${node_entitlements}")
  if [[ "${identity}" != "-" ]]; then
    dsh_arguments+=(--hardened)
    if [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID Application"* ]]; then
      dsh_arguments+=(--timestamp)
    fi
  fi
  /usr/bin/python3 "${SRCROOT}/Scripts/sign-embedded-dsh-runtime.py" "${dsh_arguments[@]}"
  node "${SRCROOT}/Scripts/verify-embedded-dsh-runtime.mjs" "${embedded_dsh}" darwin "${runtime_architecture}"
fi

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && \
  -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && \
  "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]
then
  arguments=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime)
  if [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID Application"* ]]; then
    arguments+=(--timestamp)
  fi
  /usr/bin/codesign "${arguments[@]}" "${service_path}"
  /usr/bin/codesign --verify --strict --verbose=2 "${service_path}"
fi

print "Verified embedded CodexBridgeService and resources for ${ARCHS}."
