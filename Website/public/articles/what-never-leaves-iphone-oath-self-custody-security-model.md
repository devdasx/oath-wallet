# Oath’s Current Security Model: Local Keys and Explicit Network Boundaries

Oath Editorial · Originally published 2026-08-31 · Updated November 2, 2026

https://articles.oathwallet.org/what-never-leaves-iphone-oath-self-custody-security-model

Understand the protected local vault, password-encrypted backups, and what public network requests reveal.

## Current release guidance

Checked against [Oath 5.0.0 (102) source](https://github.com/devdasx/oath-wallet/tree/7f40ec1158237c9358a30cf127efb26eef16a7a0). Build 102 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Local credentials

The 5.0.0 source keeps recovery input and signing material in an authenticated AES-GCM vault. Storage uses device-only Keychain items plus an installation key in a protected, backup-excluded app-container file. When enabled, the app passcode protects the vault key with PBKDF2-HMAC-SHA256 using 600,000 rounds.

## What network services receive

Blockchain and price providers receive the public queries needed for balances, history and fees. Signed transactions are broadcast after review. Providers can observe request metadata and public addresses; self-custody does not make network use anonymous.

## Explicit backup and export

An eligible iCloud backup is encrypted locally with a separate password before upload. A deliberate phrase or key export reveals recovery material to the owner and may create a copy outside the protected vault. Never put that copy in a support message.

## WalletConnect

User-approved dApp connections can share public accounts and signatures through encrypted relay sessions. A request can still authorize an unsafe on-chain action. Review the network, destination and permissions; disconnecting a session does not revoke existing on-chain approvals.

## Release evidence and limits

The public release has no operator upload path for wallet credentials, recovery typing, wallet records or diagnostics. Its source, archive and upload checks are documented. They are not an independent audit or a proof that compromised devices cannot expose secrets.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v5.0.0).
