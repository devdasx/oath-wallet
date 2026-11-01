# Aezeed bridge source and reproduction

The bridge calls LND v0.19.3-beta aezeed with its production scrypt parameters.
The module graph is pinned in go.mod/go.sum. The toolchain used for the review
is Go 1.26.5 and Xcode 27.0 (27A266a), on arm64 macOS.

From this directory:

```sh
go mod verify
go test -race -count=1 ./...
go vet ./...
go run ./cmd/seedvectors
go run ./cmd/vectors
bash build.sh
```

The default output replaces only Packages/OathAezeed/OathAezeedCore.xcframework
in the current checkout. An optional first argument selects a separate output:
`bash build.sh /tmp/OathAezeedCore.xcframework`. Use a disposable checkout.
The script compiles all three arm64 slices; it does not launch a simulator or device.

The build pins Go 1.26.5, suppresses VCS and debug-path/build-ID metadata, sets
`ZERO_AR_DATE=1`, and sorts the XCFramework library descriptors. Two independent
source/output/cache paths with Xcode 27.0 (27A266a) produced identical hashes for
all ten framework files. `Packages/OathAezeed/BuildProvenance.json` records the
source inputs and output hashes. Reproduce with the same compiler and SDK;
other toolchain versions are not claimed to yield identical binaries.

These newly rebuilt archives replace the earlier opaque artifacts. Existing
public seed/password fixtures still decode identically. The original reconstruction
failure remains documented in OW-2026-002: equality with the historical shipped
archives is **not established** and is not implied by the new reproducible build.

All test inputs are deliberately public fixtures. Never fund these keys.
The bridge and its dependencies are covered by the notices in
../../Packages/OathAezeed/THIRD_PARTY_NOTICES.txt.
