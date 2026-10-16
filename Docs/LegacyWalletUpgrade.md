# Legacy wallet upgrade

## Approved migration policy

The migration follows the user's latest instruction: import recovery material
using the new app's existing wallet rules. It does **not** add retired address
types, preserve an old-only receive type, or copy old address-discovery caches.
Wallet IDs, names, order, created/imported identity and active selection remain.
Original public account metadata is retained inside the encrypted vault for
provenance. Addresses can differ where the new default derivation differs from
the old selection. This is not an exact-address compatibility layer.

On 2026-10-16 the user explicitly chose: “Keep current rules; stop safely for
unsupported wallets.” Unsupported historical formats therefore block the entire
upgrade, retain the originals and show the recovery message; they are never
silently omitted or converted into a different kind of wallet.

## Storage and authentication findings

Old checkout: `/Volumes/MacOSDisk/evm app`, target `Oath`.
New checkout: `/Volumes/MacOSDisk/Oath App`, target `OathAtmosphere`.
Both use bundle `com.aperture.wallet`, team `C5T44SZNQX`. New version/build is
4.0.3/77, above the inspected old 4.0.2/76. The new entitlement explicitly
includes `$(AppIdentifierPrefix)com.aperture.wallet`.

Old public metadata lives in Application Support/WalletDatabase/wallet.sqlite
(GRDB SQLite, including WAL; complete-until-first-user-authentication file
protection). SQLite is not application-encrypted. Recovery material is separate
in device-bound, non-synchronizing, unlocked-only Keychain items under service
`com.codex.prototype.evmwallet.secrets`. SQL stores references, not secrets.

Recovery credentials are raw UTF-8 BIP-39 phrases or a versioned JSON envelope
with mnemonic, passphrase and recovery scheme. Single-key wallets store 32-byte
keys and format markers. Bitcoin imports can store descriptors wrapping a key
or extended private node. The migration reads neither balances nor history.

The old six-digit PIN uses a salted PBKDF2-HMAC-SHA256 verifier (210,000 rounds;
the reader also accepts the old supported 310,000-round variant). Its backup
alias is used only if the primary verifier is absent/corrupt, never for a wrong
PIN. Existing lockout deadlines/counters seed a durable migration throttle.
PIN authentication happens before wallet Keychain reads. The same digits then
protect the new AES-GCM vault with its normal 600,000-round KDF.

If the old persisted settings explicitly disable the PIN, migration preserves
that choice and uses the new installation-bound encrypted storage. It does not
invent a PIN or require a missing old verifier. Old Face ID cannot be copied as
a new biometryCurrentSet enrollment: after authenticating with the existing
PIN, the user explicitly reenrolls or chooses PIN-only protection. The pending
choice survives restart inside authenticated ciphertext; Home remains gated.

## Supported material and deliberate boundaries

- BIP-39 created/imported wallets, including original recovery passphrases.
- Recognized single-key import formats for chains supported by the new app,
  including compressed/uncompressed Bitcoin-family keys and Solana seeds.
- Bitcoin descriptor collections representing one identical scalar or one
  identical BIP32 private node. The existing importer receives the full extended
  key, including chain code; no new scripts/address types are installed.
- Long passphrases accepted by the old app are retained with the old Wallet Core
  behavior. Backup version 7 carries an authenticated compatibility flag so a
  backup/restore cannot silently drop them. New-wallet passphrase limits remain.

Electrum/Aezeed/Muun recovery schemes, silent-payment recovery material, unrelated
multi-key collections, watch-only/hardware records and other formats without a
current import representation are **not** claimed as supported. Such an input
stops the whole migration with a clear message before writing a destination
vault. Originals remain recoverable. These cases need a separate compatibility
implementation if a future release is intended to migrate every historical
format. They are deliberate exclusions under the approved current-rules policy.

## Commit and recovery protocol

1. Read old public records before new-vault or reset routing. A legacy snapshot
   without a matching V2 completion stamp takes precedence over pre-release
   wallets, their PIN, and an interrupted test-app reset. Only absence or a valid
   empty legacy database falls through to normal new-app startup. Corrupt/locked
   legacy data fails closed.
2. Authenticate; recheck the source fingerprint before reading wallet secrets.
3. Prepare all wallets using current import/derivation rules. Verify the original
   recorded public keys against the recovery material at their original paths
   (or an independently derived address when an early row lacks a public key).
   Descriptor imports verify the original primary public key using their node,
   chain code and relative path. These verification paths do not become new
   receiving/signing options. Reject mismatched, unsupported or missing material
   before committing anything.
4. Verify the complete serialized candidate, invalidate any previous completion
   stamp, then atomically insert/replace the encrypted vault with its SQL journal.
   Replacement does not decrypt the obsolete test vault. Read back and authenticate
   the candidate before publishing destination metadata.
5. Replace test wallet rows, ledger/history, settings, active selection and old
   receipts in one SQL transaction. Clear obsolete reset intent in that transaction.
   Verify all imported rows before commit; any error rolls back the entire SQL
   replacement. A per-candidate replacement receipt makes journal replay idempotent.
   Clear the encrypted journal only after the SQL commit succeeds.
6. Remove test biometric credentials, unlock counters, local custody outbox and
   dApp authorization bindings; retain the legacy Face ID transition gate. Write
   an installation-encrypted source completion stamp only after verification and
   cleanup. Before this stamp, a restart reauthenticates the original source and
   rebuilds safely. After it, normal new-app unlock preserves subsequent edits and
   changed PINs. A changed legacy source is migrated again after authentication.
7. Resume Home and normal live balance/history sync. No old disposable data is
   copied. Original legacy records remain recoverable throughout.

Migration never modifies/deletes the old database or old Keychain entries and
never queues recovery material for a network service. An explicitly confirmed
future Reset App retains its existing legacy-data cleanup behavior.
Diagnostics use the shared privacy-filtered pipeline and fixed stage/error
identifiers; no recovery material, PINs, wallet names/IDs, or Keychain references
are included.

## Verification performed on 2026-10-16

One dedicated iPhone 17 Pro Max / iOS 27.0 simulator:
`DF5D2160-52B0-4328-9C7A-BB72BA424996` (`Oath Legacy Upgrade`).
No other simulator was changed and no physical device was used.

The old app was installed/launched, and an explicitly gated test used its real
creation/import and persistence APIs to create 13 synthetic wallets: four created,
four mnemonic imports and five private-key imports (EVM, TRON, Solana, Bitcoin,
Litecoin). Names differ, one is Arabic, and wallet 8 was selected. Fixtures include
a normal passphrase and a 300-character legacy passphrase. Original storage had
234 account rows; the new rules produce 306 account rows.

The new app replaced the old app in place using the same bundle. No uninstall,
simulator erase, or deletion of the original database/Keychain was performed.
A guarded test reset only the new synthetic destination between policy/security
variants; the legacy IDs had to match the public fixture manifest first.

| Check | Result and evidence |
| --- | --- |
| Protected old-to-new update, current import rules | Passed; `/tmp/oath-legacy-current-rules-2.xcresult` |
| Disable PIN using old production API, then update in place | Passed; `/tmp/oath-legacy-disable-passcode.xcresult`, `/tmp/oath-legacy-unprotected-1.xcresult` |
| Every name/type, previous active wallet, 306 account signing checks | Passed using synthetic challenge signatures verified locally; no transaction broadcast |
| Independent address comparison against old app | 208 addresses with unchanged paths matched; changed defaults are intentionally not claimed identical |
| Home routing, fresh balances, completed history fetch | Passed; `/tmp/oath-legacy-home-1.xcresult` |
| Repeat launch without resetting migrated data; encrypted backup round trip | Passed; `/tmp/oath-legacy-repeat-final.xcresult`, `/tmp/oath-legacy-relaunch-verification.xcresult` |
| Real process termination/relaunch | Home displayed the previous selected wallet; `/tmp/oath-legacy-relaunch-home.png` |
| Wrong PIN, durable throttle, missing keys, interruptions before/after SQL, retry/idempotency, no PIN, biometric transition, clean/corrupt routing, current defaults, extended-key chain code, mixed-key rejection, mismatched recovery material, unsupported-wallet atomic rejection | 12 simulator regressions passed; `/tmp/oath-legacy-ownership-faults.xcresult` |
| Final ownership verification and fresh migration of all 13 old-app fixtures | Passed; 306 signing checks and fresh Home data again; `/tmp/oath-legacy-ownership-integration.xcresult` |
| Bitcoin ownership derivation against a published BIP84 address and existing key import cases | 7 host tests passed; `/tmp/oath-legacy-bitcoin-ownership.log` |
| SQL source/atomicity/idempotency/occupied-destination tests | 6 host tests passed; `/tmp/oath-legacy-database-tests.log` |
| Passphrase/backup compatibility | 4 passphrase and 16 backup-document host tests passed; `/tmp/oath-legacy-cloud-tests.log`, `/tmp/oath-legacy-backup-document-tests.log` |
| Shared diagnostics | 52 host tests executed, 2 skipped, no failures; coverage guard passed (498 catch sites); `/tmp/oath-legacy-diagnostics-ownership.log` |
| Generic iOS compilation with final ownership checks | Passed; `/tmp/oath-legacy-generic-ownership.log` |

The clean-install regression uses an isolated empty source location and empty
vault/database in the same simulator. It is not a destructive wipe/reinstall of
the upgrade simulator. Interruption regressions inject failures at the exact
vault/SQL boundaries; they are not a physical power-loss test. Fresh data checks
prove new provider observations/history completion, not universal provider uptime.

## Required physical-device/release checks

Simulator Keychain access does not prove distribution entitlement compatibility.
Before release, verify a distribution-signed upgrade on a physical iPhone,
including old Keychain access group, locked-device/reboot/file protection,
Face ID reenrollment/cancel/change of biometric set, PIN fallback, and app
termination during migration. Also verify the installed production legacy schema
and all recovery formats actually present in the user population. No claim of
100% correctness or complete historical-format coverage is made from these tests.

## Follow-up: passcode unlock blocked by a stale migration receipt

The user reported installing the App Store version over a previous Xcode build,
then updating to the new app again. Shared `app_errors` reports at
2026-10-16 02:43 and 02:46 UTC identify `LegacyUpgradeError.conflictingReceipt`
from `OathWalletSession.unlock`. This is a failure after vault authentication:
the pending encrypted SQL journal and the database's migration fingerprint
disagree. The fingerprint includes legacy security/settings and the serialized
reader schema, so a mismatch alone is not evidence of different wallet keys.
The installed phone's data was not inspected; the precise event that caused its
two receipts to diverge is not established.

Previously any mismatch prevented every subsequent unlock. Recovery now checks
each journal wallet's ID, vault reference, kind, creation/deletion state, and each
account's wallet/network/address/path/index against the committed database in
one transaction. Only a fully matching projection can repair the receipt. Names,
appearance, order, selected wallet, settings, live sync generations and additional
accounts are left intact. Missing or different identities still fail closed;
this is not a merge of unrelated old/new vaults. The authenticated vault also
checks that its migration journal authorizes only its own members and references.
No PIN reset, protection downgrade, original-data deletion, or secret reimport
is involved. Shared diagnostics record a fixed receipt-mismatch identifier and
stage with operation correlation, without wallet data or fingerprints.

Follow-up checks actually performed:

- 10 database host tests passed, including changed legacy security fingerprints,
  verified receipt repair, 11 incompatible/missing identity variants, unchanged
  user edits, and privacy of the emitted diagnostic.
  Evidence: `/tmp/oath-legacy-receipt-db-final.log`.
- Four targeted tests passed on the same dedicated iPhone 17 Pro Max simulator:
  wrong PIN cannot repair a receipt; successful PIN completes recovery; a second
  interruption during journal cleanup is restart-safe; three subsequent unlocks
  preserve membership/selection/protection; foreign journal membership is rejected;
  the existing before/after SQL interruption regressions still pass.
  Evidence: `/tmp/oath-legacy-receipt-recovery.xcresult`.
- Diagnostics host suite: 52 executed, two skipped, zero failures. Coverage guard
  passed (498 catch sites). Generic iOS build passed.
  Evidence: `/tmp/oath-legacy-receipt-diagnostics.log`,
  `/tmp/oath-legacy-receipt-generic.log`.

No physical-device install, launch, Keychain inspection, or Face ID check was
performed for this follow-up. The simulator regression uses synthetic encrypted
vaults and real SQLite storage; it does not establish the exact phone's state.


## Follow-up: legacy data wins over pre-release test wallets (2026-10-16)

The prior receipt fix did not address coexistence. `OathWalletSession.load`
required a missing new vault before reading legacy data; `migrateLegacy` also
unlocked the existing new vault and refused an occupied SQL destination. Thus a
new -> App Store -> new installation sequence could select the test vault's PIN
and pending receipt instead of authenticating the old app.

The user explicitly authorized discarding new-app test data when legacy wallets
exist. The protocol above now implements that replacement. No old app files or
old Keychain credentials are removed, and no authentication is bypassed. The V2
completion stamp prevents repeated normal launches from replacing valid migrated
wallets. The original V1 receipt-repair logic remains for older pending journals.

Validation actually performed for this follow-up:

- Database host suite: 12 migration tests passed. Replacement rollback, obsolete
  reset/receipt handling, post-commit name/selection preservation and empty ledger
  assertions are included. `/tmp/oath-legacy-priority-db.log`.
- Shared reset regression suite: three host tests passed.
  `/tmp/oath-legacy-priority-reset.log`.
- Dedicated iPhone 17 Pro Max simulator: 22 targeted migration tests passed,
  including startup with an unreadable test vault and pending reset; old PIN
  required while a different test PIN exists; missing keys preserve test storage;
  obsolete installation-wrapped ciphertext replacement; retry at vault-write,
  SQL/journal and completion-stamp boundaries; changed legacy source; ordinary
  launches with a changed new PIN; existing unsupported-format and biometric
  transition regressions. `/tmp/oath-legacy-priority-regressions-final.xcresult`.
  One initial test failure was fixture leakage into the simulator's shared
  legacy source; the test now supplies its own database and passes.
- OathDiagnostics: 52 host tests executed, two skipped, zero failures.
  `/tmp/oath-legacy-priority-diagnostics.log`.
- Diagnostics coverage guard passed (498 catch sites). Generic unsigned iOS
  build passed. `/tmp/oath-legacy-priority-generic-final.log`.

No physical iPhone was used. These runtime checks use synthetic data, real
SQLite and the installation encryption layer; they do not prove App Store
signing/Keychain access or Face ID on the user's phone. The prior thirteen-wallet
in-place upgrade evidence above was not rerun in this follow-up. The integration
fixture now optionally supports seeding a conflicting new test vault, but that
additional gated scenario is not included in the results claimed here.
