# WalletCore distribution symbols

Current release: [4.1.14 (98) verification record](../../releases/4.1.14.md). Historical checks below describe their original scope; they are not an independent audit of this release.


The pinned 4.8.4 binary XCFrameworks omit dSYMs. Trust Wallet publishes the
matching debug symbols as separate assets on the [same release](https://github.com/trustwallet/wallet-core/releases/tag/4.8.4).

Before the first archive on a new machine, run:

```sh
python3 Tools/PrepareWalletCoreSymbols.py
```

This verifies the upstream ZIP SHA-256 values and the device build UUIDs, then
keeps only the iOS arm64 symbols in this package's ignored `.build/symbols`
directory. Do not commit the large generated symbol cache. The Xcode phase
`Include WalletCore release symbols` checks the actual embedded framework UUIDs
and copies the matching dSYMs to the archive's symbol directory. It does not
download files during a build or add debug symbols to the installed app.

When upgrading the binary package, update the pinned symbol assets/checksums and
UUIDs in the preparation tool at the same time. Mismatched or missing symbols
fail the archive with an actionable error instead of silently producing another
incomplete archive. Ordinary builds and simulator builds skip symbol copying.
The phase declares each input/output explicitly and retains Xcode's script sandbox.

Validate an archive locally before distribution:

```sh
python3 Tools/CheckDistributionArchive.py "/path/to/Oath.xcarchive"
```

This checks the archived app's orientation declarations and requires a matching
debug-symbol UUID for the main executable and every embedded framework. It does
not upload the archive or replace App Store Connect's validation.
