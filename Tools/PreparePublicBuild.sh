#!/bin/sh
set -eu
release_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
private_directory="$release_root/OathApp/Private"
configuration="$private_directory/TokenRPC.plist"
umask 077
mkdir -p "$private_directory"
if [ ! -e "$configuration" ]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$configuration"
fi
printf '%s\n' 'Local build configuration is ready. Existing values were preserved.'
