#!/bin/zsh
set -euo pipefail

allow_ad_hoc=0
if (( $# == 1 )); then
  app_argument="$1"
elif (( $# == 2 )) && [[ "$1" == "--ad-hoc" ]]; then
  allow_ad_hoc=1
  app_argument="$2"
else
  print -u2 "Usage: ${0:t} [--ad-hoc] SIGNED_APP"
  exit 64
fi

readonly app="${app_argument:A}"
readonly app_binary="${app}/Contents/MacOS/CodexBridge"
readonly service="${app}/Contents/Resources/CodexBridgeService"
readonly helper="${app}/Contents/Helpers/tunnel-client"
readonly deepseek_bundle="${app}/Contents/Resources/BridgeCore_BridgeDeepSeekHarnessACP.bundle"
readonly deepseek_template="${deepseek_bundle}/Contents/Resources/cordis.yml"
readonly embedded_dsh="${app}/Contents/Resources/EmbeddedDSH"

[[ -d "${app}" && ! -L "${app}" ]] || { print -u2 "App bundle is missing or unsafe."; exit 66; }
for component_path in "${app}" "${service}" "${helper}" "${deepseek_bundle}" "${deepseek_template}"; do
  [[ -e "${component_path}" && ! -L "${component_path}" ]] || { print -u2 "Missing release component: ${component_path}"; exit 66; }
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
for spec in "BridgeCore_BridgePiRPC.bundle:PiBridgeExtension/index.mjs" \
  "BridgeCore_BridgeQoderSDK.bundle:QoderHost/index.mjs" \
  "BridgeCore_BridgeClaudeSDK.bundle:ClaudeHost/index.mjs" \
  "BridgeCore_BridgeDeepSeekHarnessDesktop.bundle:DSHDesktopConnector/index.mjs"; do
  bundle="${app}/Contents/Resources/${spec%%:*}"
  entry="${bundle}/Contents/Resources/${spec#*:}"
  [[ -d "${bundle}" && ! -L "${bundle}" && -f "${entry}" && ! -L "${entry}" ]] || {
    print -u2 "Release Agent resources are missing or unsafe: ${spec%%:*}"
    exit 66
  }
done
readonly details="$(/usr/bin/codesign -dvv "${app}" 2>&1)"
if (( allow_ad_hoc == 0 )); then
  [[ "${details}" == *"TeamIdentifier="* && "${details}" != *"TeamIdentifier=not set"* ]] || {
    print -u2 "Release app has no Developer ID team identifier."; exit 65
  }
  [[ "${details}" == *"flags=0x10000(runtime)"* || "${details}" == *"flags=0x10000(runtime,"* ]] || {
    print -u2 "Hardened Runtime is not enabled on the release app."; exit 65
  }
fi

readonly app_team="${details##*TeamIdentifier=}"
readonly app_team_id="${app_team%%$'\n'*}"
readonly expected_architectures="$(/usr/bin/lipo -archs "${app_binary}" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
for component in "${service}" "${helper}"; do
  if (( allow_ad_hoc == 0 )); then
    component_details="$(/usr/bin/codesign -dvv "${component}" 2>&1)"
    component_team="${component_details##*TeamIdentifier=}"
    component_team_id="${component_team%%$'\n'*}"
    [[ -n "${component_team_id}" && "${component_team_id}" == "${app_team_id}" ]] || {
      print -u2 "Component team identifier does not match the app: ${component}"; exit 65;
    }
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "${component}"
  component_architectures="$(/usr/bin/lipo -archs "${component}" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
  [[ "${component_architectures}" == "${expected_architectures}" ]] || {
    print -u2 "Component architectures do not match the app: ${component}"
    exit 65
  }
done

case "${expected_architectures}" in
  "arm64 ") runtime_architecture=arm64 ;;
  "x86_64 ") runtime_architecture=x64 ;;
  *) print -u2 "Embedded DSH requires one release architecture."; exit 65 ;;
esac
node "${0:A:h}/verify-embedded-dsh-runtime.mjs" "${embedded_dsh}" darwin "${runtime_architecture}"
embedded_node_relative="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node"])' "${embedded_dsh}/runtime.json")"
embedded_node="${embedded_dsh}/${embedded_node_relative}"
if (( allow_ad_hoc == 0 )); then
  node_details="$(/usr/bin/codesign -dvv "${embedded_node}" 2>&1)"
  node_team="${node_details##*TeamIdentifier=}"
  [[ "${node_team%%$'\n'*}" == "${app_team_id}" ]] || {
    print -u2 "Embedded Node team identifier does not match the app."
    exit 65
  }
fi
/usr/bin/codesign --verify --strict --verbose=2 "${embedded_node}"
node_architectures="$(/usr/bin/lipo -archs "${embedded_node}" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "${node_architectures}" == "${expected_architectures}" ]] || {
  print -u2 "Embedded Node architecture does not match the app."
  exit 65
}

if (( allow_ad_hoc == 1 )); then
  print "Ad hoc release package verified for ${app}."
else
  print "Release hardening verified for ${app} (Team ID ${app_team_id})."
fi
