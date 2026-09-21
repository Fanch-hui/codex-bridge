#!/bin/zsh
set -euo pipefail

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"
readonly candidate_script="${script_directory}/build-release-candidate.sh"
readonly hardening_script="${script_directory}/verify-release-hardening.sh"
readonly ci_workflow="${repository_root}/.github/workflows/ci.yml"

check_contains() {
  local needle="$1"
  local file="$2"
  /usr/bin/grep -Fq -- "${needle}" "${file}" || {
    print -u2 "Release contract is missing '${needle}' in ${file}."
    exit 1
  }
}

/bin/zsh -n "${candidate_script}" "${hardening_script}"
check_contains 'REQUIRE_TUNNEL_HELPER=YES' "${candidate_script}"
check_contains 'verify-release-hardening.sh' "${candidate_script}"
check_contains '--ad-hoc' "${candidate_script}"
check_contains 'codesign --verify --deep --strict' "${hardening_script}"
check_contains 'CODE_SIGNING_ALLOWED=NO' "${ci_workflow}"
check_contains 'REQUIRE_TUNNEL_HELPER=NO' "${ci_workflow}"

print 'Release candidate and ordinary CI signing boundaries are wired.'
