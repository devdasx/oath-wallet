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

Before the first archive on a new machine, run:

```sh
python3 Tools/PrepareWalletCoreSymbols.py
```

This verifies the published ZIP SHA-256 values and device build UUIDs, then
keeps the iOS arm64 symbols in this package's ignored `.build/symbols`
directory. Do not commit the large generated symbol cache. The Xcode phase
`Include WalletCore release symbols` checks the embedded framework UUIDs and
copies matching dSYMs into the archive's symbol directory. It does not download
files during a build or add debug symbols to the installed app.

When changing the binary package, update both binary-target checksums, the
symbol-asset checksums and UUIDs together. Missing or mismatched symbols fail
the archive. Ordinary and simulator builds skip archive symbol copying.

Validate an archive before distribution:

```sh
python3 Tools/CheckDistributionArchive.py "/path/to/Oath.xcarchive"
```

That checks orientation declarations and matching debug-symbol UUIDs for the
executable and embedded frameworks. It does not upload or submit the app.
