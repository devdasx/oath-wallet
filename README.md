# Oath Wallet 5.0.2

A native multichain wallet for iPhone and iPad.

**Apple-approved release: 5.0.2 (104).** This release adds receipt and asset-list improvements, a Solana history-date repair, native typography, and further audit fixes. App Store Connect shows Ready for Distribution, confirmed on 5 November 2026.

[Published security review and remaining scope](https://github.com/OathWallet/oath-wallet-security-review) · [Current release metadata](https://oathwallet.org/release-status.json)

[Release notes](releases/5.0.2.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- Adds sender totals with separately denominated fees, and identifies wallet-owned Bitcoin inputs and change outputs in receipts.
- Repairs legacy Solana transaction dates offline while preserving history, cached receipts, and reset boundaries.
- Shows asset symbols, full names, network badges, and both native and fiat balances in asset selection and search.
- Uses native system typography across supported languages and keeps completed iCloud backup status visible.
- Preserves signing revocation after wallet removal, rejects invalid history checkpoints, and hardens NEAR/Sui/XDR/SCALE parsing and Stellar plan timestamp bounds.
- Includes the public audit repairs made after build 103: interrupted wallet-import recovery, wallet ordering and Bitcoin address discovery.
- Improves encrypted backup file handling and stale-progress protection, and clears revealed private keys when the app leaves the foreground.
- Hardens malformed WalletConnect encodings and XRP amount/simulation validation.
- Preserves pending transaction journals during wallet removal and recovers interrupted removal safely.

## Public source boundaries

This public repository includes the app, bundled assets, local packages, patched
Reown dependency, tests, and the complete [website, Help Center and articles](Website/README.md).
Website service implementations and [deployment workflows](Distribution/README.md) are also public.
Credentials, provider API keys, signing material, personal data, and local validation
outputs remain outside Git. Website services are separate from the self-custodial iOS app. Remote recovery-phrase collection and its upload integration
are absent. Recovery input stays local; signing happens on the device.

Diagnostics retain the shared privacy filter and bounded local outbox. This public
build has no diagnostic upload transport or operator endpoint. Optional encrypted
iCloud backup is separate from diagnostics and requires your own Apple capability
configuration. Never put real wallet material in tests, issues, or support reports.

## Release verification

The [5.0.2 (104) release](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.2-build104) identifies this source and build settings. Its [verification record](releases/5.0.2.md) distinguishes new checks from earlier audit evidence. Apple approval and source/build verification are separate: approval does not establish a completed audit or an independently reproduced source-to-store binary match.

The [5.0.0 (102) delivery record](releases/5.0.0.md) documents the earlier build delivered to Apple.

Source review, secret scanning, compilation and focused tests are performed during
release preparation. These are maintainer-directed checks, not an independent
security audit or a reproducible comparison of Apple's redistributed binary.

## Build

Use Xcode 27 and Swift 6. The app deployment target is iOS 17; individual visual
features use availability checks for newer system versions.

```sh
git clone https://github.com/OathWallet/oath-wallet.git
cd oath-wallet
sh Tools/PreparePublicBuild.sh
open OathAtmosphere.xcodeproj
```

Select the **OathAtmosphere** scheme, which builds **Oath Wallet**. Dependencies are
pinned by package manifests and `Package.resolved`. The checked-in project can be
regenerated with XcodeGen using `project.yml`.

The preparation script only creates an empty, ignored local provider configuration.
No API key is needed to compile. Network-backed features and WalletConnect require
your own provider configuration; see [PublicBuild.md](Documentation/PublicBuild.md).
Device signing and iCloud require your own Apple development team.

Compile without launching a simulator or installing on a device:

```sh
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/oath-public-build CODE_SIGNING_ALLOWED=NO build
```

## Validation

```sh
python3 Tools/ValidatePublicRelease.py --scan
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
python3 Tools/CheckMultiWallet.py --lifecycle
```

Secret-scanner exceptions are restricted to reviewed public fixtures and syntax
false positives. Their file hashes are checked by the release validator; changes
require renewed review. Live network tests are opt-in. Simulator, device, and
App Store results must be reported separately from source and host tests.

For security issues, use [private vulnerability reporting](https://github.com/OathWallet/oath-wallet/security/advisories/new).
See the bundled third-party notices and dependency licenses for attribution.

## Reproducible security review

A [maintainer-commissioned, Codex-led review](https://github.com/OathWallet/oath-wallet-security-review)
now tracks the [5.0.2 (104) release](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.2-build104).
Earlier audit results retain their original tested commits; the current target and remaining work are recorded in the review repository.
It publishes its exact source targets, findings, tests, and outstanding coverage.
The review is **in progress**, is not independent certification, and does not
establish equivalence with Apple's distributed binary. Later changes do not
automatically inherit its conclusions.
