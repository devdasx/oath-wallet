# Oath Wallet release history and current version

Read the confirmed Oath release record, what changed in version 5.0.2 and where to find version-specific wallet guides.

This page separates confirmed App Store distribution from source-code releases. A GitHub tag or prerelease does not, by itself, mean an update is available in the App Store.

## Current confirmed release: 5.0.2 (104)

The [distribution record](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.2-distribution.json) records Ready for Distribution, confirmed on November 5, 2026. Check the [official App Store page](https://apps.apple.com/app/id6780187283) for availability on your device and in your storefront.

The [5.0.2 release notes](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.2.md) describe these changes:

- Transaction receipts distinguish transferred assets and network fees in their native units. Bitcoin receipts identify wallet-owned inputs and change.
- A repair corrects affected Solana history dates, including cached receipts, without changing balances or transaction data.
- Asset search and selection show symbols, full names, network badges and balances more clearly.
- Native system typography is used across supported languages, and completed iCloud backup status stays visible.
- Reliability work covers interrupted imports, encrypted backup handling, transaction journals and validation of supported signing requests.

Read [transaction status](https://help.oathwallet.org/articles/transaction-status), [network fee requirements](https://oathwallet.org/networks/fees), [encrypted iCloud backup](https://oathwallet.org/features/icloud-wallet-backup) and [WalletConnect scope](https://oathwallet.org/features/walletconnect) for the practical details. The [security page](https://oathwallet.org/security) explains the evidence and its limitations.

## Earlier source releases

The public records for [5.0.1](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.1.md), [5.0.0](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.0.md) and [4.1.15](https://github.com/OathWallet/oath-wallet/blob/main/releases/4.1.15.md) preserve their changes and verification scope. They are historical source records, not a claim that every intermediate build was distributed by Apple.

Older help screenshots retain the version in which they were captured. An older capture can explain a workflow without representing the exact appearance of the current app.

## How we maintain this record

Oath Wallet maintains this page from the repository's release and distribution records. We add an App Store release only when distribution evidence is recorded; we keep source checks, runtime checks and independent security review distinct. This page was reviewed on November 6, 2026.

For a correction, send the page URL and a description through [Oath support](https://help.oathwallet.org/). Do not send recovery words, keys or backup passwords. See [our product-documentation policy](https://oathwallet.org/about#editorial).
