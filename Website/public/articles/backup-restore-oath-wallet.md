# Backup and Restore in Oath: Files, Passwords and Recovery Words

Oath Editorial · Originally published 2026-08-30 · Updated October 30, 2026

https://articles.oathwallet.org/backup-restore-oath-wallet

Choose a recovery method supported by 4.1.14 and verify it before replacing or erasing your phone.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/e98eba14186da8afe21c46fb9466afd464f498e1). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Choose the recovery material

A BIP39 wallet needs its original recovery words and any additional BIP39 passphrase. A private-key wallet needs its original key in the supported network format. Electrum and aezeed have separate Bitcoin recovery rules; preserve their words and required seed extension or password. A valid import is not proof that you recovered the intended account: compare a known public address.

## Create an eligible iCloud backup

Open Settings → Backup, or the selected wallet’s backup section. Choose a separate backup password of at least eight characters and confirm it. Oath encrypts each eligible wallet into its own .oathbackup file before writing to your iCloud Drive. Check each wallet’s completed status. Preparing or uploading is not yet a usable backup.

## Know what is excluded

Electrum and aezeed wallets are not eligible for iCloud backup in 4.1.14. Recently Deleted wallets are excluded from Back Up All Wallets. Keep manual recovery material for excluded wallets. A backup does not reproduce every cached balance, transaction note or app setting.

## Restore and verify

Enable iCloud Drive for the Apple Account holding the file. Choose Restore from iCloud, select the file, and enter the password used to encrypt that file. The app passcode, a passkey and Apple Account access alone cannot decrypt it. Allow the download and local save to finish, then compare the restored wallet’s public addresses and refresh balances.

## Keep a second recovery route

Oath cannot reset a forgotten backup password. If the original wallet still opens, create a new supported backup and retain its password. Removing the app does not delete separate iCloud files. Do not erase the old phone until the replacement wallet and recovery material are verified.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).
