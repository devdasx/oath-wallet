#!/bin/sh
# Xcode resource phase: a clean checkout can build without a provider key.
# Never echo this resource or expose credentials in build settings.
set -eu
token_rpc_source="${SRCROOT}/OathApp/Private/TokenRPC.plist"
token_rpc_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/TokenRPC.plist"
mkdir -p "$(dirname "$token_rpc_output")"
if [ -f "$token_rpc_source" ]; then
    /bin/cp "$token_rpc_source" "$token_rpc_output"
else
    # Also replace a stale configured resource when the local key is removed.
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$token_rpc_output"
fi
