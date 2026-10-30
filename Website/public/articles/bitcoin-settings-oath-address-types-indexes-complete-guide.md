# Bitcoin Address Types and Recovery Scope in Oath

Oath Editorial · Originally published 2026-09-11 · Updated October 30, 2026

https://articles.oathwallet.org/bitcoin-settings-oath-address-types-indexes-complete-guide

Match the address type and imported key scope; changing the visible format does not change the blockchain.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/e98eba14186da8afe21c46fb9466afd464f498e1). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Available address families

For compatible Bitcoin wallets, Receive offers Taproot (BIP86), Native SegWit (BIP84), nested SegWit (BIP49) and Legacy (BIP44). The available choices depend on your imported material. An uncompressed single key supports Legacy only; a scoped extended key cannot recreate unrelated branches.

## Receive and change

A new receiving address can belong to the same wallet. Change addresses account for value returned to your wallet by a transaction. The scan covers supported imported branches rather than only the currently selected display type. It does not guarantee discovery beyond the implemented account and gap rules.

## Electrum and aezeed

These are Bitcoin-specific recovery formats. Preserve the original seed extension or password. Aezeed account-zero recovery covers supported on-chain paths; it does not recover Lightning channels or arbitrary custom accounts.

## Unsupported recovery methods

Silent Payments receiving and discovery are not supported in 4.1.14. Do not treat an sp1 destination as ordinary Taproot, and do not assume an old BRD-specific recovery menu or screenshot exists in this build. Keep the original wallet when the required account format is unsupported.

## Before sending or receiving

Confirm the exact network, full recipient address and required fee. Refresh and compare known addresses before relying on a restore. A published example address or screenshot is not a receiving address for your wallet.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).






















<!-- oath-walkthrough:start -->
## Bitcoin: know the address and recovery scope — visual walkthrough transcript

Guidance checked against 4.1.14 (98) source on October 30, 2026. Included screenshots are historical examples. This is an illustrated guide, not a recording of a current App Store test.

### 1. Match the address family

Use the Bitcoin address types offered for the imported material. Compatible wallets include Native SegWit, Taproot, nested SegWit and Legacy.

### 2. Understand receiving addresses

A fresh HD receiving address can belong to the same wallet. A single key or scoped extended key has narrower recovery scope.

### 3. Recognize change

Change returns unspent value to an address controlled by the wallet. Generated addresses are not evidence of received funds.

### 4. Check current limits

Silent Payments receiving and discovery are not supported in 4.1.14. Preserve the original format, account information and any required passphrase.

[Open the visual walkthrough](https://oathwallet.org/articles/bitcoin-settings-oath-address-types-indexes-complete-guide#visual-walkthrough)
<!-- oath-walkthrough:end -->
