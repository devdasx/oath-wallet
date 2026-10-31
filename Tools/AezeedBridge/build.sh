#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd ../.. && pwd)"
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
    go build -buildmode=c-archive -trimpath -o "$build/$target/libOathAezeedCore.a" .
  cp include/OathAezeedCore.h "$build/$target/headers/"
  cp include/module.modulemap "$build/$target/headers/"
done
out="$root/Packages/OathAezeed/OathAezeedCore.xcframework"
rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$build/mac/libOathAezeedCore.a" -headers "$build/mac/headers" \
  -library "$build/ios/libOathAezeedCore.a" -headers "$build/ios/headers" \
  -library "$build/sim/libOathAezeedCore.a" -headers "$build/sim/headers" \
  -output "$out"
