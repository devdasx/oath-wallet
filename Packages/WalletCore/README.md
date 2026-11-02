# Repaired Wallet Core distribution

Oath 4.1.15 (100) selects Wallet Core 4.8.4 with eight reviewed source repairs.
The upstream source pin is `d40d24a63d92619167903369308bf0e2f7eb3a59`.
[The public security-review repository](https://github.com/devdasx/oath-wallet-security-review)
contains the patches, exact input pins, build scripts and before/after evidence.
`provenance.json` records this package's selected artifacts and checksums.

The repairs cover dependency constructor validation, extended-key validation,
entropy cleanup, aliased buffer append, stale result-wrapper state, and rejected
serialized signing/planning input. Findings distinguish dependency defects from
established application reachability. They do not imply an independent audit,
whole-wallet completion or verification of an installed App Store binary.

The public rebuild procedure compiles the pinned C/C++, Rust and Swift sources
and packages generic iOS and universal iOS simulator frameworks. The matching
Swift protobuf runtime is pinned to 1.29.0; its generator is pinned to 1.18.0,
matching the upstream generation pipeline. Dependency deployment minimum is
now iOS 15; the application's iOS 26 minimum is unchanged.

## Device archive symbols

The two pinned XCFrameworks include their matching device symbols. Xcode copies them into the archive. The release workflow checks the UUIDs of both archived frameworks and their dSYMs against the package provenance before uploading the IPA.

To perform the same check on an archive, run `python3 Tools/CheckArchiveSymbols.py "/path/to/Oath.xcarchive"`.
