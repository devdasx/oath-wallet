# Move Oath to a New iPhone Using a Supported Recovery Method

Oath Editorial · Originally published 2026-08-30 · Updated October 30, 2026

https://articles.oathwallet.org/move-oath-to-new-iphone-direct-encrypted-serverless

Use the original recovery material or an eligible password-encrypted backup; verify the new wallet before erasing the old phone.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/e98eba14186da8afe21c46fb9466afd464f498e1). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Check the installed versions

The 4.1.14 source does not include the former nearby-iPhone transfer flow. Do not follow old screenshots that ask you to pair a source and destination phone. Keep the old phone available while you choose a supported import or backup route.

## If you have a supported iCloud backup

On the old phone, check that the relevant wallet’s upload completed. Keep the password used for that file. On the new phone, enable the correct iCloud Drive account, choose Restore from iCloud and enter that password. Each wallet has its own backup file.

## If you have recovery words or a private key

Use Import wallet or Import private key and the original format. Include a required BIP39 passphrase, Electrum extension or aezeed password. A private key keeps its selected network scope. Electrum and aezeed must use manual recovery material because their iCloud backup is unavailable in 4.1.14.

## Verify before removing anything

Compare known public addresses, the expected networks and refreshed balances. A matching wallet name is not enough. For an older wallet with Silent Payments outputs, Lightning channels or unsupported custom accounts, retain the compatible original software and recovery material; 4.1.14 cannot discover those funds simply by importing the words.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).






















<!-- oath-walkthrough:start -->
## A new iPhone: recover and verify — visual walkthrough transcript

Guidance checked against 4.1.14 (98) source on October 30, 2026. Included screenshots are historical examples. This is an illustrated guide, not a recording of a current App Store test.

### 1. Choose a supported route

Use original recovery material or an eligible password-encrypted iCloud file. The former nearby-iPhone transfer flow is not included in 4.1.14.

### 2. Keep the correct credentials

BIP39, Electrum and aezeed have different rules. Preserve the required passphrase or password. A private key keeps its original network scope.

### 3. Restore an eligible file

Enable the correct iCloud Drive account, choose Restore from iCloud, select the file and enter the password used to encrypt it. Electrum and aezeed wallets are not eligible.

### 4. Verify before erasing

Compare known public addresses and refreshed activity. Unsupported Silent Payments, Lightning channels and custom accounts require compatible recovery tools.

[Open the visual walkthrough](https://oathwallet.org/articles/move-oath-to-new-iphone-direct-encrypted-serverless#visual-walkthrough)
<!-- oath-walkthrough:end -->
