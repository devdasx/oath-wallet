# Aezeed bridge source and reproduction

The bridge calls LND v0.19.3-beta aezeed with its production scrypt parameters.
The module graph is pinned in go.mod/go.sum. The toolchain used for the review
is Go 1.26.5 and Xcode 27.0 (27A266a), on arm64 macOS.

From this directory:

```sh
bash test.sh
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

## Dependency repairs

Both scripts prepare a disposable vendor tree from the pinned Go modules.
`prepare_source.py` verifies downloaded modules, verifies the exact upstream
hashes of three files, applies `dependency-repairs.patch`, then verifies every
changed path and its repaired hash against `DependencyRepairs.json`. It never
patches the shared module cache. `prepared-source.json` records all vendor and
bridge input hashes. The runtime uses the resulting vendor tree explicitly.

These repairs reject partial CBC blocks and short outputs before mutation,
reject out-of-range BLAKE2b state parameters before changing the receiver, and
encode all three GCM length fields with 64-bit bit lengths. These APIs are
outside the bridge's traced aezeed decoding path; this is dependency hardening,
not a claim that an exploitable wallet vulnerability was found.

The tests exercise real dependency implementations, including 512 MiB synthetic
GCM AAD, nonce and plaintext boundaries. Allow several GiB of memory for the
race-instrumented tests. Plain `go test` in this directory uses the unpatched
upstream modules and deliberately fails the new regressions. Use `test.sh` to
test the same patched source preparation used by `build.sh`.

The serialized wallet format, aezeed scrypt settings and C ABI are unchanged.
Successful host tests or reproducible archives do not imply historical App
Store binary equivalence or whole-wallet security certification.
