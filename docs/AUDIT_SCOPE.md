# Oath Wallet 4.0.0 source review scope

This document describes the source release, version 4.0.0, build 73. It is a review
entry point for an independent auditor, not an independent audit certificate or
proof of equivalence to a separately distributed App Store binary.

## Secret boundaries

- `WalletCoreService.swift` creates and imports credentials locally.
- `WalletSecretVault.swift` stores secrets in non-synchronizing,
  `WhenUnlockedThisDeviceOnly` Keychain items. `WalletDatabaseRecords.swift` and
  wallet/account persistence store opaque references and public wallet data.
- Recovery and private-key input stay in local state. The application delegate
  rejects third-party keyboards; credential inputs disable Writing Tools and
  prediction. Sensitive screens enforce authentication, masking and expiry.
- `Send/` resolves wallet-scoped signing authorization and signs locally. Network
  requests carry public queries or signed transactions, not spending credentials.
- `WalletAutomaticCloudBackupService.swift` encrypts the backup payload with
  AES-GCM. `WalletICloudBackupKeyVault.swift` protects the backup key using the
  user's verified passkey PRF. The historical relying-party and Keychain names
  are compatibility identifiers, not provider credentials.
- `DeviceMigration/` encrypts the secret bundle to a locally paired device using
  the authenticated pairing exchange. Secret material is separate from the
  portable database. Known Silent Payments outputs prevent direct transfer
  because this release cannot rediscover them on the destination.
- Authenticated export is intentionally available to the wallet owner. Copy
  actions use local-only clipboard entries with expiry. Exported material is
  outside the app's protection once shared by the user.

## Public data and connectivity

Balances, prices, history, fee estimates, address discovery and transaction
broadcast use public network infrastructure and configured provider proxies.
These services can observe queried public addresses, script hashes and network
metadata. Self-custody is not a claim of network anonymity.

Optional push registration includes public wallet addresses, wallet names, APNs
tokens and device metadata. Feedback opens a user-controlled email draft; sending
it is a separate action in the user's mail application.

`AssetCatalogSyncService.swift` reads a release-packaged snapshot. Its production
client has no HTTP client, authentication, or publication operation. The 2,348
catalog entries reference bundled PNG artwork through the `oath-asset` scheme.
Catalog changes require a source/app update; public market prices still refresh.

## Silent Payments boundary

Sending to supported Silent Payments recipients is locally signed. New Silent
Payments receiving and discovery are unavailable until an on-device scanner has
been implemented and reviewed. The scanner entry points fail closed and have no
transport or private-key serialization implementation.

Already-known outputs can be exported and signed locally. Their public script
history and UTXOs are reconciled without reading a scan key. Missing provider
history preserves cached records and produces an error; it does not prove an
output disappeared. A public refresh never advances a discovery checkpoint or
claims completeness. Send preparation refreshes the known outputs before coin
selection. Bitcoin screens explain the limitation, including after phrase restore.

Unseen Silent Payments cannot be discovered after restoring a phrase on a new
device. Direct transfer is blocked when known outputs exist. Keep the source
device and export the relevant output keys through the authenticated export flow.
Standard Bitcoin address receiving and local signing remain supported.

## Review and validation

The review traced secret reads, persistence, input handlers, network serialization,
logging, signing, backup and migration paths across the Swift source. No active
mnemonic or private-key upload path was identified in the reviewed application code.
This conclusion is limited to the inspected source and tested paths.

Validation includes:

- A clean simulator build-for-testing with Xcode 27.
- An optimized Release build for arm64 and x86_64 iOS Simulator, with the product
  metadata verified as Oath Wallet 4.0.0, build 73. A compiled-bundle check found
  no disallowed backend or private-key scanning endpoint strings.
- A 97-test run covering local catalog installation, credential safety, Keychain
  persistence, secret export, authorization, expiry and migration hardening.
- An 85-test regression run covering known-output reconciliation, failure
  preservation, transfer blocking, Bitcoin signing/coin selection, export, input
  protection, catalog installation and local database secret exclusion.
- A final 63-test run across five suites after the last fixes, covering Bitcoin
  refresh and coin selection, migration, backup discovery and credential inputs.
- After renaming the source, tests and Xcode project to Oath, a simulator build
  through the `Oath` scheme and 19 tests across four suites passed, covering
  bundled resources, wallet persistence, backup discovery and credential inputs.
- Branding validation and localization validation across all 57 locales.
- The publication gate in `Scripts/validate_source_release.py` and a redacted
  Gitleaks scan with zero unresolved findings. Exact reviewed exclusions are
  documented in `.gitleaksignore` and `docs/TEST_FIXTURES.md`.

These automated tests use disposable wallets and public test vectors, not live
funds. A global HTTP interception experiment was not usable on this simulator;
network-boundary conclusions rely on source review and deterministic public-client
fixtures, not a claimed comprehensive packet capture.

Wallet Core and other pinned dependencies remain part of the trust boundary.
The prebuilt Wallet Core frameworks, Apple platform security, external providers,
physical-device behavior and independently distributed binaries were not
independently audited by these checks. No 100% security guarantee is made.
