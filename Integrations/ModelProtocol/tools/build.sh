#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  printf '%s\n' 'Usage: build.sh <darwin|windows|linux> <amd64|arm64> <output-file>' >&2
  exit 2
fi
case "$1/$2" in
  darwin/amd64|darwin/arm64|windows/amd64|windows/arm64|linux/amd64|linux/arm64) ;;
  *) printf '%s\n' 'Unsupported OS or architecture.' >&2; exit 2 ;;
esac

module=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_bin=${GO:-go}
output=$3
case "$output" in /*) ;; *) output=$(pwd)/$output ;; esac
cd "$module"
CGO_ENABLED=0 GOOS=$1 GOARCH=$2 GOTOOLCHAIN=local "$go_bin" build \
  -trimpath -mod=readonly -o "$output" ./cmd/model-protocol
