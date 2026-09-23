# Oath Wallet

**An open-source, self-custody wallet for iPhone and iPad.**

This repository contains the **4.0.0 source release (build 73)**, with the Oath Wallet
name and official interlocking-rings identity. It is prepared for independent audit.
The statements below describe this source tree; they do not establish a match to a
separately distributed App Store binary.

[Website](https://oathwallet.org) · [Security](SECURITY.md) · [Audit scope](docs/AUDIT_SCOPE.md) · [MIT license](LICENSE)

## Features

- On-device wallet creation, recovery-phrase and private-key import, local signing,
  multiple wallets and network-specific address validation.
- Bitcoin-family wallets, account discovery, transaction history, fee selection,
  send/receive flows, coin control and supported wallet-backup import formats.
- Optional BIP-39 passphrases and physical-entropy wallet creation.
- Optional passkey-protected encrypted iCloud backup and encrypted nearby-device
  transfer, with explicit user authorization for sensitive operations.
- App locking, protected secret screens, timed authorization and clipboard expiry.
- Native iPhone/iPad navigation, light/dark appearance, accessibility and 57 localizations.
- A packaged catalog of 2,348 assets, local token artwork, custom-token support,
  market information, asset families including bStocks, and optional notifications.
- Credential-entry protection against third-party keyboards and system Writing Tools.

## Supported mainnets

**Bitcoin family:** Bitcoin, Bitcoin Cash, Litecoin and Dogecoin.

**EVM:** Ethereum, BNB Smart Chain, Arbitrum One, Base, Polygon, OP Mainnet,
Avalanche C-Chain, Gnosis, Linea, Scroll, Taiko, Telos, X Layer and Arc.

**Other networks:** Solana, TRON, TON, Sui, Aptos, NEAR, Stellar and XRP Ledger.

Silent Payments receiving and discovery are unavailable in this release pending
a reviewed local scanner. Existing discovered outputs can be exported and spent;
restores cannot discover unseen Silent Payments. Direct device transfer is blocked
when known Silent Payments outputs exist; retain the source device and export
the output keys before restoring elsewhere. Standard Bitcoin receiving and
local signing remain supported.

Capabilities and supported import formats vary by network. Token listings and
market data are informational; verify asset identity and transaction details.

## Custody and network boundaries

Wallet credentials are generated or imported on the device and held in
non-synchronizing, this-device-only Keychain items. The wallet database stores
references to those items. Signing runs locally; network providers receive public
queries and signed transactions. There is no operator-held recovery credential in
this source design.

Optional iCloud backup encrypts the wallet payload before upload and protects the
backup key with the user's passkey PRF. Nearby-device transfer encrypts to a paired
peer. Users remain responsible for their recovery material and passkeys.

Public RPC, price and history services still learn the public data queried through
them. Optional push registration sends public wallet addresses, wallet names,
notification tokens and device metadata. User-requested feedback opens an email
draft to `care@oathwallet.org` for review and sending in the user's mail app.
See [the audit scope](docs/AUDIT_SCOPE.md) for the relevant code and limitations.

## Build

Requirements: Xcode 27, Swift 6 and an iOS 26+ simulator or compatible device.

```sh
git clone https://github.com/devdasx/oath-wallet.git
cd oath-wallet
open Oath.xcodeproj
```

Select the `Oath` scheme. It builds the product named **Oath Wallet**.
Application sources are in `Oath/` and tests are in `OathTests/`. The internal
Swift module and wallet storage identifiers retain their compatibility names.
The checked-in Xcode project is authoritative; do not regenerate it with XcodeGen.
Swift Package Manager downloads the pinned dependencies, including Wallet Core
binary frameworks. A build does not require a bundled provider API key. Public
provider proxy URLs are configuration, not credentials. Device installation and
iCloud/APNs capabilities require a developer's own Apple signing configuration.

For a simulator build, choose its UUID with `xcrun simctl list devices available`:

```sh
xcodebuild build -project Oath.xcodeproj -scheme Oath \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/oath-wallet-derived-data
```

## Review and validation

Run `python3 Scripts/validate_source_release.py` for the source-publication gates.
Run `gitleaks dir . --redact` for credential detection with the reviewed public
fixture exclusions in `.gitleaksignore`. These checks supplement manual review;
they do not certify security.

The audit entry points and validation results are recorded in
[`docs/AUDIT_SCOPE.md`](docs/AUDIT_SCOPE.md). No independent security audit is
claimed. Contributions should include focused tests and avoid live-mainnet calls
unless explicitly enabled.

## Contact and license

Website: [oathwallet.org](https://oathwallet.org). Support/security:
[care@oathwallet.org](mailto:care@oathwallet.org) (mailbox activation is pending).
Do not send recovery phrases or private keys to support or post them in issues.

MIT licensed; see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
