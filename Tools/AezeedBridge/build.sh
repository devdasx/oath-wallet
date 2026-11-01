#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd ../.. && pwd)"
# Pin the Go compiler and remove host/VCS/debug-path metadata from archives.
# ZERO_AR_DATE also normalizes Apple's archive symbol-table timestamp.
export GOTOOLCHAIN=go1.26.5 GOWORK=off GOFLAGS= ZERO_AR_DATE=1
export CGO_CFLAGS="-O2 -g0" CGO_CPPFLAGS= CGO_CXXFLAGS="-O2 -g0" CGO_LDFLAGS="-O2 -g0"
build="$(mktemp -d /tmp/oath-aezeed.XXXXXX)"
trap 'rm -rf "$build"' EXIT
for target in mac ios sim; do
  mkdir -p "$build/$target/headers"
  case "$target" in
    mac) sdk=macosx; os=darwin; triple=arm64-apple-macos15.5 ;;
    ios) sdk=iphoneos; os=ios; triple=arm64-apple-ios17.0 ;;
    sim) sdk=iphonesimulator; os=ios; triple=arm64-apple-ios17.0-simulator ;;
  esac
  CGO_ENABLED=1 GOOS="$os" GOARCH=arm64 CC="$(xcrun --find clang) -target $triple -isysroot $(xcrun --sdk "$sdk" --show-sdk-path)" \
    go build -mod=readonly -buildvcs=false -buildmode=c-archive -trimpath -ldflags='-s -w -buildid=' -o "$build/$target/libOathAezeedCore.a" .
  cp include/OathAezeedCore.h "$build/$target/headers/"
  cp include/module.modulemap "$build/$target/headers/"
done
out="${1:-$root/Packages/OathAezeed/OathAezeedCore.xcframework}"
rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$build/mac/libOathAezeedCore.a" -headers "$build/mac/headers" \
  -library "$build/ios/libOathAezeedCore.a" -headers "$build/ios/headers" \
  -library "$build/sim/libOathAezeedCore.a" -headers "$build/sim/headers" \
  -output "$out"

# Xcode emits library descriptors in nondeterministic completion order.
python3 - "$out/Info.plist" <<'PYTHON'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
value = plistlib.loads(path.read_bytes())
value["AvailableLibraries"].sort(key=lambda item: item["LibraryIdentifier"])
path.write_bytes(plistlib.dumps(value, sort_keys=True))
PYTHON
