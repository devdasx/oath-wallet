# BIP39 Passphrases and Electrum Seed Extensions in Oath

Oath Editorial · Originally published 2026-08-30 · Updated October 30, 2026

https://articles.oathwallet.org/add-bip39-passphrase-oath-wallet

A passphrase derives another wallet; it is not an app lock or backup-file password.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/c21cc32c275b51f2a6c32af4475b279bde59c946). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## BIP39 passphrase wallets

Open a supported recovery-phrase wallet and choose Add Passphrase. Enter and confirm the exact intended value, including case and spaces, then choose the new wallet’s name and color. Every different passphrase derives different accounts; it does not encrypt the existing account with a new login password.

## Electrum differs

A supported Electrum seed extension uses Electrum’s own normalization and derivation rules. It is not a BIP39 passphrase. Some Electrum seed types do not accept extensions. Use only the option the app provides for the original seed type.

## Record the complete recovery method

Keep the original words and correct extension together in a secure recovery plan. The app passcode is separate, and the password of an eligible .oathbackup file is separate again. Private-key, multisignature and aezeed wallets do not offer the BIP39 Add Passphrase flow.

## Backup eligibility

Eligible BIP39 passphrase backups encrypt the passphrase with the recovery payload. Electrum and aezeed wallets are excluded from iCloud backup in 4.1.14, so retain their original manual recovery material. Verify known public addresses before receiving funds.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).
