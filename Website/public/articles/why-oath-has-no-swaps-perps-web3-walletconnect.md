# WalletConnect in Oath: Review the Request, Control the Permission

Oath Research · Originally published 2026-09-04 · Updated October 30, 2026

https://articles.oathwallet.org/why-oath-has-no-swaps-perps-web3-walletconnect

Oath now supports WalletConnect. Understand the difference between a session, a signature and an on-chain approval.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/c21cc32c275b51f2a6c32af4475b279bde59c946). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## What changed

Earlier Oath versions did not include WalletConnect. That older product boundary no longer describes 4.1.14: supported dApps can connect through encrypted WalletConnect relay sessions. Use the current connection screens and supported-chain guidance.

## Connection is not unlimited approval

Review the dApp identity, proposed accounts and networks before connecting. Public account access does not justify every later transaction or signature. Read each request and decline anything you cannot explain.

## Transactions and swaps

A dApp can prepare a swap or another contract interaction. The wallet reviews and signs supported requests locally after approval. The route, contracts, recipient and spending authority still matter; a readable screen or familiar dApp name is not a guarantee of safety.

## Disconnect versus revoke

Disconnecting closes a session. Existing on-chain token or account permissions can remain until a supported revocation transaction succeeds. Revocations require fees and can fail; multiple revocations are not one atomic operation.

## Keep recovery material private

A legitimate connection uses public accounts and requested signatures, not your recovery phrase or private key. Never type recovery material into a dApp, support message or web-based troubleshooting form.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).
