#!/bin/zsh

set -euo pipefail

if [[ $# -eq 0 || "${1:-}" == "--help" ]]; then
    print -u2 -- "Usage: Scripts/xcodebuild_isolated.sh <xcodebuild arguments>"
    print -u2 -- "Creates a unique DerivedData directory for this invocation."
    exit $(( $# == 0 ? 64 : 0 ))
fi

for argument in "$@"; do
    if [[ "$argument" == "-derivedDataPath" ]]; then
        print -u2 -- \
            "error: this wrapper owns -derivedDataPath; remove it from the arguments"
        exit 64
    fi
done

temporary_root="${TMPDIR:-/tmp}"
derived_data_path=$(mktemp -d \
    "${temporary_root%/}/aperture-xcodebuild.XXXXXX")

print -u2 -- "Using isolated DerivedData: $derived_data_path"

/usr/bin/xcodebuild \
    -derivedDataPath "$derived_data_path" \
    "$@"
