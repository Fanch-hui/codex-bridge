#!/bin/zsh
set -euo pipefail

readonly TUNNEL_CLIENT_VERSION="0.0.17"
readonly TUNNEL_CLIENT_COMMIT="a248b7f725fc989c1eb26680cf4351ee33421f61"
readonly AMD64_ARCHIVE_NAME="tunnel-client-v${TUNNEL_CLIENT_VERSION}-darwin-amd64.zip"
readonly ARM64_ARCHIVE_NAME="tunnel-client-v${TUNNEL_CLIENT_VERSION}-darwin-arm64.zip"
readonly RELEASE_BASE_URL="https://github.com/openai/tunnel-client/releases/download/v${TUNNEL_CLIENT_VERSION}"
readonly AMD64_ARCHIVE_SHA256="1d54cc57e0a624dc733d402f7d36585f2135a23ddc32c4cb52a7253c7d8d94a0"
readonly ARM64_ARCHIVE_SHA256="df03ad0ba9c95c22951bab6833df289469f15b9a3fa0397d95e3d568d1ff6c1f"
readonly LICENSE_URL="https://raw.githubusercontent.com/openai/tunnel-client/${TUNNEL_CLIENT_COMMIT}/LICENSE"
readonly LICENSE_SHA256="f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4"
readonly NOTICE_SHA256="1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2"
readonly MANIFEST_LINE_COUNT=19

if (( $# != 2 )); then
  print -u2 "Usage: ${0:t} HELPER_DIRECTORY TRUSTED_UNSIGNED_SHA256"
  exit 64
fi

readonly requested_helper_directory="$1"
readonly trusted_unsigned_sha256="$2"
(( ${#trusted_unsigned_sha256} == 64 )) && \
  [[ "${trusted_unsigned_sha256}" != *[^0-9a-f]* ]] || {
  print -u2 "Trusted unsigned SHA-256 must be 64 lowercase hexadecimal characters."
  exit 64
}
[[ -d "${requested_helper_directory}" && ! -L "${requested_helper_directory}" ]] || {
  print -u2 "Helper directory must be a non-symlink directory: ${requested_helper_directory}"
  exit 72
}
readonly helper_directory="${requested_helper_directory:A}"
readonly helper="${helper_directory}/tunnel-client"
readonly license="${helper_directory}/LICENSE"
readonly notice="${helper_directory}/NOTICE"
readonly manifest="${helper_directory}/tunnel-client.manifest"
for file in "${helper}" "${license}" "${notice}" "${manifest}"; do
  [[ -f "${file}" && ! -L "${file}" ]] || {
    print -u2 "Missing regular helper artifact: ${file:t}"
    exit 66
  }
done
[[ -x "${helper}" ]] || {
  print -u2 "Tunnel helper is not executable."
  exit 66
}
[[ ! -e "${helper_directory}/cloudflared" && ! -L "${helper_directory}/cloudflared" && \
  ! -e "${helper_directory}/cloudflared-manifest.json" && \
  ! -L "${helper_directory}/cloudflared-manifest.json" ]] || {
  print -u2 "Refusing helper bundle containing cloudflared."
  exit 65
}

manifest_value() {
  local key="$1"
  local -a values
  values=("${(@f)$(/usr/bin/awk -F= -v key="${key}" '$1 == key { print substr($0, length($1) + 2) }' "${manifest}")}")
  (( ${#values} == 1 )) || {
    print -u2 "Manifest key must occur exactly once: ${key}"
    return 1
  }
  print -r -- "${values[1]}"
}

expect_manifest_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(manifest_value "${key}")"
  [[ "${actual}" == "${expected}" ]] || {
    print -u2 "Unexpected manifest value for ${key}."
    return 1
  }
}

sha256() {
  local digest
  digest="$(/usr/bin/shasum -a 256 "$1")"
  print -r -- "${digest%% *}"
}

readonly manifest_line_count="$(/usr/bin/awk 'END { print NR }' "${manifest}")"
[[ "${manifest_line_count}" == "${MANIFEST_LINE_COUNT}" ]] || {
  print -u2 "Unexpected manifest line count."
  exit 65
}

expect_manifest_value manifest.version 1
expect_manifest_value component openai/tunnel-client
expect_manifest_value upstream.version "${TUNNEL_CLIENT_VERSION}"
expect_manifest_value upstream.commit "${TUNNEL_CLIENT_COMMIT}"
expect_manifest_value archive.darwin-amd64.file "${AMD64_ARCHIVE_NAME}"
expect_manifest_value archive.darwin-amd64.url "${RELEASE_BASE_URL}/${AMD64_ARCHIVE_NAME}"
expect_manifest_value archive.darwin-amd64.sha256 "${AMD64_ARCHIVE_SHA256}"
expect_manifest_value archive.darwin-arm64.file "${ARM64_ARCHIVE_NAME}"
expect_manifest_value archive.darwin-arm64.url "${RELEASE_BASE_URL}/${ARM64_ARCHIVE_NAME}"
expect_manifest_value archive.darwin-arm64.sha256 "${ARM64_ARCHIVE_SHA256}"
expect_manifest_value derived.file tunnel-client
expect_manifest_value derived.architectures x86_64,arm64
expect_manifest_value derived.unsigned.sha256 "${trusted_unsigned_sha256}"
expect_manifest_value license.file LICENSE
expect_manifest_value license.url "${LICENSE_URL}"
expect_manifest_value license.sha256 "${LICENSE_SHA256}"
expect_manifest_value notice.file NOTICE
expect_manifest_value notice.source.commit "${TUNNEL_CLIENT_COMMIT}"
expect_manifest_value notice.sha256 "${NOTICE_SHA256}"

[[ "$(sha256 "${helper}")" == "${trusted_unsigned_sha256}" ]] || {
  print -u2 "Derived tunnel helper SHA-256 mismatch."
  exit 65
}
[[ "$(sha256 "${license}")" == "${LICENSE_SHA256}" ]] || {
  print -u2 "Tunnel helper license SHA-256 mismatch."
  exit 65
}
[[ "$(sha256 "${notice}")" == "${NOTICE_SHA256}" ]] || {
  print -u2 "Tunnel helper NOTICE SHA-256 mismatch."
  exit 65
}

verify_attribution() {
  local name="$1" expected="$2"
  [[ -f "${helper_directory}/${name}" && ! -L "${helper_directory}/${name}" && \
    "$(sha256 "${helper_directory}/${name}")" == "${expected}" ]] || {
    print -u2 "Tunnel helper attribution SHA-256 mismatch: ${name}"
    exit 65
  }
}
verify_attribution licenses-darwin-amd64.txt ecc5a0ec1cc5c7b16f3d1c2ddb8fb111b738b75a31e03f91c4540345106057a2
verify_attribution sbom-darwin-amd64.spdx.json 9d3da401f87911e403d2ecc99b350fc536100daf4863b53c953c382dd7998dc7
verify_attribution licenses-darwin-arm64.txt f18edf70eaa393e9441fda1ec7ad2471323efc75e1cfd3346679e1ba3854ee02
verify_attribution sbom-darwin-arm64.spdx.json 24d3559dfca40214787ac3448fdf35d6ac6cdc63d652d083025645625504349f

/usr/bin/lipo "${helper}" -verify_arch x86_64
/usr/bin/lipo "${helper}" -verify_arch arm64
readonly architectures="$(/usr/bin/lipo -archs "${helper}")"
local_architecture_count=0
for architecture in ${(z)architectures}; do
  case "${architecture}" in
    x86_64|arm64) local_architecture_count=$((local_architecture_count + 1)) ;;
    *)
      print -u2 "Unexpected helper architecture: ${architecture}"
      exit 65
      ;;
  esac
done
(( local_architecture_count == 2 )) || {
  print -u2 "Tunnel helper must contain exactly x86_64 and arm64 slices."
  exit 65
}
print "Statically verified OpenAI tunnel-client v${TUNNEL_CLIENT_VERSION} Universal 2 helper."
