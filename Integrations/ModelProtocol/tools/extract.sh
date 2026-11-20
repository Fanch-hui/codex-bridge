#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' 'Usage: extract.sh <pinned-magpie-source.tar.gz> <empty-output-directory>' >&2
  exit 2
fi

archive=$1
output=$2
revision=f9492fd8ed2c6fd3c65f1dab00062771b551d7b5
base=magpie-$revision
module=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_bin=${GO:-go}

if [ -d "$output" ] && [ -n "$(ls -A "$output")" ]; then
  printf '%s\n' 'Output directory must be empty.' >&2
  exit 2
fi
mkdir -p "$output/internal"
output=$(CDPATH= cd -- "$output" && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/bridge-model-protocol.XXXXXXXX")
trap 'rm -rf -- "$temp"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$temp" --strip-components=1 \
  "$base/internal/gateway" "$base/internal/provider" "$base/internal/catalog" \
  "$base/internal/redact" "$base/internal/capre" "$base/internal/lazyre" \
  "$base/internal/claudeseal" "$base/LICENSE"

PACKAGE=gateway SELECTORS=decode,start,event,finish,add,UnmarshalJSON,MarshalJSON,Read \
SLICEDIR="$output/internal/gateway" "$go_bin" run "$module/tools/extract.go" "$temp/internal/gateway" \
  parseChat parseResponses parseAnthropic buildChat buildResponses buildAnthropic \
  chatDecoder responsesDecoder anthropicDecoder chatEncoder responsesEncoder anthropicEncoder \
  newSSEWriter readSSE collector renderChat renderResponses renderAnthropic streamEncoder \
  afterParse carryReasoning replyEnds upstreamStop hasUnportableCurrentImage unportableVideo \
  anthropicReplaysThinking withThinkingOnToolTurns withFields

PACKAGE=provider SELECTORS= SLICEDIR="$output/internal/provider" \
  "$go_bin" run "$module/tools/extract.go" "$temp/internal/provider" \
  APIError CommandCodePlanID DeepSeekHost FlatName ObjectRoot OpenAIHost Protocol \
  Chat Responses Anthropic Gemini CodeAssist ClaudeFast
PACKAGE=catalog SELECTORS= SLICEDIR="$output/internal/catalog" \
  "$go_bin" run "$module/tools/extract.go" "$temp/internal/catalog" EffortAliases
PACKAGE=redact SELECTORS= SLICEDIR="$output/internal/redact" \
  "$go_bin" run "$module/tools/extract.go" "$temp/internal/redact" Scrub ScrubJSON

for package in capre lazyre claudeseal; do
  mkdir -p "$output/internal/$package"
  cp "$temp/internal/$package/$package.go" "$output/internal/$package/$package.go"
done
cp "$temp/LICENSE" "$output/LICENSE"
