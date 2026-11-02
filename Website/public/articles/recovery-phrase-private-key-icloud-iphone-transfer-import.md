# Recovery Phrase, Private Key or Encrypted Backup: Choose the Right Import

Oath Editorial · Originally published 2026-08-30 · Updated November 2, 2026

https://articles.oathwallet.org/recovery-phrase-private-key-icloud-iphone-transfer-import

Match the recovery format, network and required passphrase to the original wallet.

## Current release guidance

Checked against [Oath 5.0.0 (102) source](https://github.com/devdasx/oath-wallet/tree/dc104f46ab53823bd8545ca5be807c941b4283a4). Build 102 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Recovery phrase

Choose Import wallet and enter the original words in order. BIP39, Electrum and aezeed have distinct validation and derivation rules. Electrum and aezeed recover supported Bitcoin accounts, not every asset associated with the original software. Aezeed does not restore Lightning channels.

## Additional passphrase

A BIP39 passphrase creates a different wallet. Preserve its exact capitalization and spaces. Electrum seed extensions and aezeed passwords follow their own rules. None of these is interchangeable with the app passcode or iCloud backup password.

## Private key

Choose Import private key and the matching network. Ethereum & EVM groups compatible EVM networks; other chains have their own accepted formats. A single key or account-scoped extended key does not recover an entire phrase wallet. Never use an online converter to guess or rewrite private material.

## iCloud backup

Restore an eligible .oathbackup file with the password that encrypted it. Keep iCloud Drive available for download. Electrum and aezeed wallets are excluded from iCloud export in 5.0.0. The old passkey and nearby-device transfer instructions are not the current flow.

## Confirm the result

Compare a known receiving address on the original network. Allow balances and history to refresh. If it differs, stop and check the original format, account path and passphrase before deleting the source wallet or assuming funds are missing.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v5.0.0-build102-r2).
