# Encrypted iCloud Drive wallet backups

Current release: [4.1.14 (98) verification record](../../releases/4.1.14.md). Historical checks below describe their original scope; they are not an independent audit of this release.


This native Foundation/CryptoKit package uses the existing
`iCloud.com.aperture.wallet` CloudDocuments container. The application is signed
as `com.aperture.wallet`, team `C5T44SZNQX`. Its public document scope is named
**Oath Wallet** in Files; documents live in **Wallet Backups**. The directory is
created by the first explicit backup, not by importing or creating a wallet.

## File format

Each immutable `Wallet-<random UUID>.oathbackup` file is a versioned UTF-8 JSON
envelope. No wallet name or mnemonic is in the filename or plaintext header.

- `header.format`: `org.oathwallet.encrypted-wallet`
- `header.version`: `1` through `21`, selected by the recovery material and required decoder capabilities
- `header.cipher`: `AES-256-GCM`
- `header.kdf`: `PBKDF2-HMAC-SHA256`
- `header.passwordNormalization`: `NFC`
- `header.rounds`: `600000`
- `header.salt`: fresh 32-byte, base64-encoded cryptographic random salt
- `sealed`: base64 of CryptoKit's combined 12-byte nonce, ciphertext and 16-byte tag

The complete header, JSON-encoded with sorted keys and without slash escaping,
is authenticated as additional data. The key is 32 bytes, derived with native
CommonCrypto from the NFC-normalized UTF-8 password (no trimming or case folding).
Canonical normalization agrees with native String confirmation equality and
preserves compatibility between keyboard encodings of the same characters.
Passwords require at least eight extended grapheme clusters and at most 1,024
UTF-8 bytes. Decoding rejects unsupported algorithms/versions/round counts,
oversized documents, invalid salt and authentication failures before returning
recovery material. Passwords and derived keys are not persisted or uploaded.

The encrypted `BackupWallet` payload contains wallet ID, stored name, artwork
color, creation date (JSONEncoder's Foundation reference-date format), and
network derivation paths/account indices. HD wallets contain mnemonic/BIP-39
language. Imported-key wallets contain an optional `privateKey` with 32-byte
key material and its explicit network scope; their mnemonic/language are empty
and account paths are `imported`. Validation rejects both material types in the
same payload. Existing HD backups without the optional fields still decode.
It is not a snapshot of ledger history,
cached balances/prices, notes, app PIN, Face ID credentials or app settings.
BIP39 passphrase wallets preserve their exact supported passphrase inside the encrypted payload. Supported multisignature payloads preserve their policy and signer recovery material. Electrum and aezeed wallets are not eligible for iCloud export in this release.
`BackupDocument.open` is the matching tested decoder. A restore caller must
also pass recovered material through the corresponding BIP-39 or private-key
validator and verify the network/algorithm scope before importing.
The app discovers eligible files, asks for the backup password and authenticates the document before local restoration.

## Lifecycle and truthfulness

The vault selects the explicitly requested wallet, checks authentication before
and after exporting, and encrypts off MainActor. An indexed, wallet-owned GRDB
outbox commits ciphertext before file I/O. Native NSFileCoordinator writes
atomically; retries accept identical bytes and refuse conflicting contents.
Each new attempt has its own filename; earlier backup files are preserved.

NSMetadataQuery runs result processing on a serial utility queue. The app
shows real upload percentages when available and an indeterminate waiting
state otherwise. Only `NSMetadataUbiquitousItemIsUploadedKey` confirms upload.
Confirmation and its date are committed to SQLite together with the wallet's
backed-up flag; the redundant outbox ciphertext is then discarded. Relaunch or
foreground entry resumes pending files without the backup password. iOS owns
the actual network transfer after the coordinated write.

An archived, local ubiquity identity token binds a job to its original iCloud
account. Comparisons use the native token's `isEqual`, not its archive hash.
Switching accounts does not redirect an existing job. Missing files, account
changes, quota errors and upload failures do not silently remain successful.
Disabling the switch clears pending local ciphertext and preserves remote files.
Passwords must be reentered when making a new backup; they are not kept for
automatic re-encryption after future metadata changes.

## Validation

Run `swift test --package-path Packages/OathCloudBackup` for native encryption,
wrong-password/tampering/bounds/Unicode and coordinated file-write checks.
GRDB migration/outbox/confirmation/stale-callback checks live in
`Packages/OathDatabase/Tests/OathDatabaseTests/CloudBackupTests.swift`.
`Tools/CheckMultiWallet.py` additionally exercises production vault export of
an inactive wallet, cancellation and locked-vault rejection with synthetic data.
No host check reads a user's wallet, uses their Keychain or uploads to iCloud.

Apple references: [container configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services),
[ubiquity account identity](https://developer.apple.com/documentation/foundation/filemanager/ubiquityidentitytoken),
[background query processing](https://developer.apple.com/documentation/foundation/nsmetadataquery/operationqueue),
[upload completion](https://developer.apple.com/documentation/foundation/nsmetadataubiquitousitemisuploadedkey).
The KDF work factor follows the [OWASP PBKDF2 guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
