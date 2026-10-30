#!/bin/sh
# Official prebuilt dependencies ship their dSYMs separately. Keep this phase
# offline; prepare the checksum-pinned cache once with PrepareWalletCoreSymbols.py.
set -eu

[ "${PLATFORM_NAME:-}" = "iphoneos" ] || exit 0
[ "${DEBUG_INFORMATION_FORMAT:-}" = "dwarf-with-dsym" ] || exit 0

symbols_root="${SRCROOT}/Packages/WalletCore/.build/symbols/ios-arm64"
for framework in WalletCore WalletCoreSwiftProtobuf; do
    source_dsym="${symbols_root}/${framework}.framework.dSYM"
    dwarf="${source_dsym}/Contents/Resources/DWARF/${framework}"
    binary="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${framework}.framework/${framework}"
    if [ ! -f "$dwarf" ]; then
        echo "error: Missing ${framework} release symbols. Run python3 Tools/PrepareWalletCoreSymbols.py before archiving." >&2
        exit 1
    fi
    binary_ids=$(/usr/bin/xcrun dwarfdump --uuid "$binary" | /usr/bin/awk '{print $2, $3}' | /usr/bin/sort)
    symbol_ids=$(/usr/bin/xcrun dwarfdump --uuid "$dwarf" | /usr/bin/awk '{print $2, $3}' | /usr/bin/sort)
    if [ -z "$binary_ids" ] || [ "$binary_ids" != "$symbol_ids" ]; then
        echo "error: ${framework} symbols do not match the linked binary. Update the pinned symbol release before archiving." >&2
        exit 1
    fi
    output_dsym="${DWARF_DSYM_FOLDER_PATH}/${framework}.framework.dSYM"
    /bin/mkdir -p "${output_dsym}/Contents/Resources/DWARF" "${output_dsym}/Contents/Resources/Relocations/aarch64"
    # Copy only declared files; recursive directory copying has undeclared
    # accesses under Xcode's script sandbox (including volume metadata files).
    for relative in "Contents/Info.plist" "Contents/Resources/DWARF/${framework}" "Contents/Resources/Relocations/aarch64/${framework}.yml"; do
        COPYFILE_DISABLE=1 /bin/cp -X "$source_dsym/$relative" "$output_dsym/$relative"
    done
    echo "Included matching ${framework} release symbols."
done
