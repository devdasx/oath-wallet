# Oath support

Contact a real person: **care@oathwallet.org** — put your iPhone model and app version in the message.

> **Oath will never ask for your recovery phrase, private key or passkey** — not by email, DM or call. Anyone who asks is trying to steal your wallet.

## Frequently asked questions

### How do I create a wallet?

_Getting started_ — Open Oath and tap “Create a new wallet”. Your keys are generated on your iPhone, then you’ll back up your recovery phrase. Creating a local wallet needs no Oath account or email.

### Can I import a wallet from another app?

_Getting started_ — Yes. Choose Import wallet and use the original BIP39, Electrum or aezeed format with any required passphrase. Electrum and aezeed restore supported Bitcoin accounts. Private keys use a separate import with the matching network. Compare a known public address before moving funds.

### Can I create my own recovery phrase with dice?

_Getting started_ — The 4.1.14 source creates standard wallets with a 12-word BIP39 phrase. The earlier dice, coin-flip and typed-digit creation controls are not included in this release.

### What if I lose my iPhone?

_Backup & recovery_ — Install Oath on a compatible iPhone or iPad and use the correct recovery phrase and any extra passphrase, or an existing encrypted iCloud backup with its backup password. Your funds live on the blockchain, not on your phone.

### Can Oath recover my recovery phrase?

_Backup & recovery_ — No. Recovery material is protected locally in the app, not held by Oath support. Keep your own recovery backup; support cannot replace missing words, keys or passwords.

### How does encrypted backup restore work?

_Encrypted backups_ — An existing Oath iCloud backup needs both the encrypted backup file in iCloud Drive and its backup password. Keep iCloud Drive and the backup password available on the new device, then follow Restore from iCloud. Apple Account access alone is not enough.

### Is an iCloud backup a replacement for my recovery phrase?

_Encrypted backups_ — For eligible wallets, it is an additional recovery method. Keep manual recovery material too. Electrum and aezeed wallets are excluded from iCloud backup in 4.1.14.

### Why is my transaction pending?

_Sending & receiving_ — Transactions confirm when the network includes them. Busy networks take longer. You can see the status and the fee you paid in the transaction details.

### What are network fees?

_Sending & receiving_ — Fees go to the network, not to Oath. A network-fee estimate is shown before you confirm; the final fee can depend on the network and transaction.

### Which address type should I use for Bitcoin?

_Sending & receiving_ — Native SegWit (bc1q) and Taproot (bc1p) are efficient Bitcoin address options. The best choice depends on sender compatibility and how your coins will be spent. Nested SegWit and Legacy are also available where supported by the imported material. Silent Payments receiving and discovery are not supported in 4.1.14.

### Someone from “Oath support” asked for my phrase.

_Security_ — That is a scam. Oath will never ask for your recovery phrase, private key or passkey. Don’t reply, and forward the message to care@oathwallet.org.

### Is Oath open source?

_Security_ — Yes. The full source is published on GitHub at github.com/devdasx/oath-wallet, with a current security model, release verification record and security policy. Public source does not establish an independent audit or a verified match to the App Store binary.

### What is EVM Access?

_EVM Access_ — A tool that shows discovered token approvals on supported EVM networks. Revoke a supported permission with an on-chain transaction; a network fee applies.

### Does revoking an approval cost a fee?

_EVM Access_ — Yes, a small network fee, because revoking is an on-chain transaction. Oath shows it before you confirm.

## Practical guides

Step-by-step help, with release notes and recovery limitations. Start with the guide that matches what you need to do.

- [Choose a backup and restore method](/articles/backup-restore-oath-wallet)
- [Restore your wallets on another iPhone](https://help.oathwallet.org/articles/move-to-new-phone)
- [Import an existing or older wallet](/articles/recovery-phrase-private-key-icloud-iphone-transfer-import)
- [Understand Bitcoin address types](/articles/bitcoin-settings-oath-address-types-indexes-complete-guide)
- [Receive on the correct network](/articles/receive-crypto-safely-network-address-qr-requested-amounts)
- [Receive crypto with a QR code](https://help.oathwallet.org/articles/receive-crypto)

[Check supported networks](/networks) · [Read the security evidence](/security)

## Security vulnerabilities

Use [GitHub private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new) and follow the [security policy](https://github.com/devdasx/oath-wallet/security/policy). Reports go privately to repository maintainers. Never include real wallet credentials or post exploit details in a public issue.
