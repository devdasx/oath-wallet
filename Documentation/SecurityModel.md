# Security model — 4.1.5 (89)

Oath Wallet keeps recovery input and signing credentials in its protected local vault. Optional encrypted iCloud backups, deliberate exports and WalletConnect requests have separate user-controlled boundaries.

## Open source and App Store builds

The technical descriptions and source excerpts on this page were checked on 28 October 2026 against Oath Wallet **4.1.5 (89)**, source commit **dd334ee70f32be22b14a521afb275468185b1a29**. Version 4.1.5 (89) is a public source release. Its App Store Connect upload-only workflow was cancelled before upload at the maintainer’s request; it was not submitted for review. See the release record for delivery and processing evidence. The public US App Store listing showed 4.1.2 when checked.

Read the [4.1.5 release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.5), [current security model](https://github.com/devdasx/oath-wallet/blob/main/Documentation/SecurityModel.md), and [security reporting policy](https://github.com/devdasx/oath-wallet/security/policy). Provider configuration and Apple signing are supplied through encrypted GitHub deployment secrets and excluded from public source.

## What the checks establish

The release record covers source inspection, secret scanning, compilation, focused host tests, and delivery of the resulting archive to Apple. No simulator or physical-device checks were run for build 89. It does not establish an independent security audit or an independently reproduced comparison with an App Store download. Apple approval alone would not establish either result.

## Recovery formats and local signing

New standard wallets use a 12-word BIP39 recovery phrase. BIP39 imports validate supported word lists and checksums locally. Electrum and aezeed imports use their own formats and restore supported Bitcoin accounts; they are not reinterpreted as BIP39. Preserve any required original passphrase and compare known public addresses after import.

Private-key imports retain their network scope. Multisignature wallets retain their signer material and policy locally; support and required setup differ by chain. Keeping several signing keys on one device does not provide independent-device security. A wallet name or successful import does not establish that every previous account has been recovered.

Source: [mnemonic validation](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Import/OathMnemonicValidator.swift), [wallet engine](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathWalletEngine.swift), [private-key import](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathPrivateKeyImport.swift), and [multisignature creation](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathMultisigCreation.swift).

## Local storage and app lock

Wallet secrets are sealed in an authenticated AES-GCM vault, stored through non-synchronizing, device-only Keychain storage. An additional installation key is kept in a protected, backup-excluded app-container file. When enabled, the app passcode protects the vault key using PBKDF2-HMAC-SHA256 with 600,000 rounds. Biometrics and the selected auto-lock delay control access. Disabling the app passcode changes that protection; device compromise remains a risk.

Public wallet records, balances and history are stored separately in the local database. Removing the app also removes its installation key; do not treat reinstalling as a recovery method.

Source: [vault envelope](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathVaultEnvelope.swift), [vault storage](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathInstallationVaultStorage.swift), [installation protection](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathInstallationSecurity.swift), and [lock policy](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Security/OathSecurityPolicy.swift).

## Password-encrypted iCloud backup

For supported wallets, Oath creates a .oathbackup file encrypted on the device with AES-256-GCM. A separate backup password derives its key using PBKDF2-HMAC-SHA256 with 600,000 rounds and a fresh 32-byte salt. Restore needs both that encrypted file and its password. The app passcode, a passkey, or Apple Account access alone cannot decrypt it.

Each eligible wallet has its own file. Electrum and aezeed wallets are excluded from iCloud backup in 4.1.5; preserve their original recovery words and required passphrase. Back Up All Wallets covers eligible active wallets, not Recently Deleted wallets. Verify each upload result. Existing iCloud files remain outside the local app-reset boundary.

Source: [backup format](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/Packages/OathCloudBackup/Sources/OathCloudBackup/BackupDocument.swift), [backup eligibility](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathWalletVault.swift), and [restore flow](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathCloudRestoreModel.swift). See the [backup guide](https://help.oathwallet.org/articles/backup-password).

## Explicit clipboard copies

Recovery phrases, private keys and passphrases are copied only after an explicit user action. These secret copies stay on the current device and use the system pasteboard’s 60-second expiry; they are excluded from Universal Clipboard. Public addresses and transaction identifiers retain ordinary clipboard behavior. Expiry cannot revoke information already pasted into another app.

## Network and diagnostic boundaries

This source release has no operator endpoint for wallet credentials, recovery typing, wallet records or diagnostic uploads. Privacy-filtered diagnostics remain in a bounded local outbox. Blockchain providers still receive public queries for balances, fees and history, and signed transactions for broadcast. WalletConnect uses encrypted relay connections for user-approved sessions and signing requests. A signature, accepted broadcast and confirmed transaction are different outcomes.

Source: [local EVM signing](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Wallet/OathEVMSigning.swift), [send service](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Send/OathEVMSendService.swift), and [WalletConnect details](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/Documentation/WalletConnectReadableDetails.md).

## Recovery limits

The 4.1.5 source does not provide Silent Payments receiving or discovery, the former nearby-iPhone transfer flow, or dice/coin/digit wallet creation. Its Bitcoin receive options depend on the imported material. Aezeed recovery covers supported on-chain Bitcoin branches, not Lightning channels or arbitrary custom LND accounts. Do not erase an older wallet until a supported recovery method reproduces its intended accounts. Never fund a public tutorial phrase or an example address.

Source: [import catalog](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/OathAtmosphere/Import/OathImportCatalog.swift), [Bitcoin keys](https://github.com/devdasx/oath-wallet/blob/dd334ee70f32be22b14a521afb275468185b1a29/Packages/OathBitcoin/Sources/OathBitcoin/BitcoinKeys.swift), and [aezeed scope](https://github.com/devdasx/oath-wallet/blob/main/Packages/OathAezeed/README.md).

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new). Include the affected version and reproduction steps using unfunded test material. Never send a real recovery phrase, private key, passphrase or backup password. Oath support cannot replace a missing recovery credential.
