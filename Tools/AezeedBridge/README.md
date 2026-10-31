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

The build replaces only Packages/OathAezeed/OathAezeedCore.xcframework in the
current checkout. Use a disposable checkout. It compiles all three arm64 slices;
it does not launch a simulator or device. This source addition does not replace
the shipped archives. The first reconstruction produced matching public seed
vectors and equal archive sizes, but different archive hashes. Consequently,
source-to-historical-binary equivalence is **not established**. See finding
OW-2026-002 in the public security review. Do not describe this as a reproducible
binary match until the remaining differences are explained and verified.

All test inputs are deliberately public fixtures. Never fund these keys.
The bridge and its dependencies are covered by the notices in
../../Packages/OathAezeed/THIRD_PARTY_NOTICES.txt.
