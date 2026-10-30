# Creating a Wallet in Oath: Current Recovery Options

Oath Editorial · Originally published 2026-08-30 · Updated October 30, 2026

https://articles.oathwallet.org/build-wallet-with-dice-coin-flips-random-digits

The current source uses standard BIP39 creation; historical dice and coin controls are not in 4.1.14.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/e98eba14186da8afe21c46fb9466afd464f498e1). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Current creation flow

Choose Create a new wallet, complete the app’s protection setup, then select the wallet name and color. The engine creates a 12-word BIP39 wallet through Wallet Core. The earlier dice, coin-flip and typed-digit creation controls are not included in 4.1.14.

## Importing existing material

Use Import wallet for supported BIP39, Electrum or aezeed words in their original format. Enter the original required passphrase or password. Importing a valid phrase does not by itself prove that the expected wallet or all its accounts were recovered.

## Why examples are not wallets

An entropy animation, tutorial phrase or screenshot is public demonstration data. Never fund it. Oath support cannot make a public phrase private or recover funds controlled by somebody else who knows the same words.

## Verify and back up

Compare the intended public address before receiving. Preserve recovery material independently of this phone. Eligible iCloud backups require a separate backup password; Electrum and aezeed wallets need manual recovery backups in this release.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).
