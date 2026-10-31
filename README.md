# Oath Wallet 4.1.15

A native multichain wallet for iPhone and iPad.

This repository contains the **4.1.15 source release, build 100**. The new app
replaces the previous source layout with `OathApp`, `OathAtmosphere`, and local
Swift packages. The application bundle identifier remains `com.aperture.wallet`.

[Release notes](releases/4.1.15-build100.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- WalletConnect support for Bitcoin, TON, TRON, Polkadot, Sui, NEAR, Stellar and XRP Ledger, with network-specific review and signing rules.
- Durable transaction recovery and account reservations for supported WalletConnect submissions.
- Network-aware scanner review and refreshed network artwork.

- Recovery phrases, private keys and passphrases copy only to this device and expire from the system clipboard after 60 seconds.

- Clearer WalletConnect access and THORChain swap reviews, with stable request-to-result presentation.
- Direct asset QR scanning, expanded payment formats, and editable memo/tag details.
- Native-fee funding guidance and safe retry preparation; verified block inclusion shown before finality.
- Refreshed Receive artwork and layout, Bitcoin OP_RETURN display, and chain-history recovery fixes.

- Share chain-specific Oath payment links from Receive and open external payment links in the Send review flow.
- Updated WalletConnect pairing metadata and expiration checks after unlock.

- Token search by network and symbol, identity-matched bundled artwork, and retained Asset Hub USDC/USDt discovery.
- XRP rolling-history recovery, safe Polkadot submission retries, and clearer self-transfer errors.
- THORChain WalletConnect compatibility with both mainnet identifiers while preserving exact session permissions.

- Chiliz, Filecoin FEVM, Sei, 0G, IoTeX and Polkadot Asset Hub support, including native-unit balances, history and sending.
- Expanded payment QR parsing, Solana Pay references, and resilient transaction tracking.

- BIP39, Electrum and aezeed recovery support, with encrypted local storage.
- Multichain asset discovery, token artwork, pricing, and transaction history.
- WalletConnect transaction review and network-aware signing integrations.
- Network-grouped permissions and batch access revocation.
- Multisignature wallet support, multiple wallets, app locking, and Recently Deleted.
- Legacy-wallet upgrade handling and improved refresh and scrolling behavior.

Capabilities vary by network, asset, provider, and configuration. Listing a
capability does not claim that every network or transaction has been tested.

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

Version 4.1.15 (100) is a source release for manual App Store Connect upload.
No Apple upload or review submission was started for this release.
See the [release record](releases/4.1.15-build100.md) for completed validation.

This release expands WalletConnect signing and transaction review to Bitcoin, TON,
TRON, Polkadot, Sui, NEAR, Stellar and XRP Ledger, with local recovery journals. Requests still require review and signing authorization.
Diagnostics remain local.

Source review, secret scanning, compilation and focused tests are performed during
release preparation. These are maintainer-directed checks, not an independent
security audit or a reproducible comparison of Apple's redistributed binary.

## Build

Use Xcode 27 and Swift 6. The app deployment target is iOS 17; individual visual
features use availability checks for newer system versions.

```sh
git clone https://github.com/devdasx/oath-wallet.git
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

For security issues, use [private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new).
See the bundled third-party notices and dependency licenses for attribution.
