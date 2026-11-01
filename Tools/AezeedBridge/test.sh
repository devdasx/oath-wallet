#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source="$PWD"
work="$(mktemp -d /tmp/oath-aezeed-tests.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export GOTOOLCHAIN=go1.26.5 GOWORK=off GOFLAGS=-mod=vendor
python3 "$source/prepare_source.py" "$work/source"
cd "$work/source/Tools/AezeedBridge"
go test -race -count=1 ./...
go vet ./...
go run ./cmd/seedvectors
go run ./cmd/vectors
