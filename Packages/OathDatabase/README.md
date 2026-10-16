# OathDatabase

Local application data uses SQLite through GRDB 7.11.1. The app owns one `DatabasePool` per file, opened by `OathDataEnvironment`. Views receive committed, immutable snapshots; they do not read provider responses or persist their own copies of balances/settings.

## Storage boundary

The database stores wallets and accounts, networks, native coins and tokens, exact balances, price samples, transactions and transfers, wallet activity, send operations, receive requests, UTXOs and their owners, notes, labels, contacts and their network addresses, settings, and sync checkpoints.

Recovery credentials, private keys, PIN authentication, biometric credentials, and installation encryption keys stay in the existing protected vault/Keychain. SQLite holds only the vault reference and public wallet metadata. No secret should be passed to the record APIs or placed in settings/notes. A signed transaction payload is broadcastable transaction data, not a signing key.

The iOS database directory and SQLite/WAL/SHM files use `completeUntilFirstUserAuthentication` protection and are excluded from device backups. This permits public transaction-status checks while locked after the first device unlock. Signing keys retain their separate vault/Keychain protection; background reconciliation never unlocks the vault. This is iOS file protection, **not SQLCipher encryption**. Deleting the app removes its database with its container. Offloading an app preserves its container, as iOS normally does. The existing installation key still controls retained Keychain records. Protected-data failures throw; they are never interpreted as a fresh install or used to erase data.

## Existing app integration

- Startup inserts missing network/native-asset definitions and refreshes their display name, symbol, and bundled logo reference in one transaction. Existing identifiers, decimals, derivation paths, sort order, enabled state, accounts, and balances remain intact. The legacy language preference migrates once. Later reads use SQL.
- Creation/import commits the protected vault first, then writes the wallet and account records in one SQL transaction. A failure between stores preserves the vault; the next authenticated unlock retries missing metadata. The two stores do not pretend to have a distributed atomic commit.
- Legacy wallet metadata is imported on its first successful unlock. Existing SQL metadata then wins, including the wallet name and backup status. Refresh never decrypts or derives the wallet again.
- The home screen observes SQL balances/prices/accounts/settings. Missing quotes/balances remain absent in storage; the existing UI can display zero without inventing a fetched balance.
- Language, balance visibility, and currency selection use database settings. Current currency defaults to the device region when no override exists.
- Chain selection reads the database network catalog. Receive presentations save receive requests; backup completion updates wallet metadata.

### Asset ordering

`AssetOrdering` is shared by portfolio holdings, receive choices and examples, contract-search results, and network choices. It orders by the wallet's holding value in USD descending, then distinct transaction count descending, then case/diacritic-insensitive name and stable network/contract/account identity. Using USD keeps the order independent of display currency and missing FX rates. Unknown valuations have monetary rank zero without changing their stored balances; raw quantities and unit prices are never compared across different assets. New unsaved assets fall back to name and identity. Exact ties stay stable rather than shuffling on refresh.

Portfolio snapshots count distinct transaction hashes per account and asset, including pending transactions. Multiple transfer logs for one transaction count once. Bitcoin-family history participates in the same count, with duplicates across history sources removed. Committed prices, balances and history all update the observed order. `v13_asset_activity_order` adds a covering activity index without rewriting wallet data. Host `AssetOrderingTests` cover value/count/name ties, wallet/account isolation, Bitcoin-family pending history, currency independence, live database observations and migration from v12.

Network adapters write through this module; screens continue reading committed local state.

### Solana ledger

`v15_solana_ledger` stores exact native/token holdings, raw inventory and transaction content, per-owner history cursors, and activity ownership. The active Phantom/Trust receive address selects the visible balance and history. A path switch invalidates in-flight writes without deleting the other path's cache. Solana prices use the shared USD tables and existing display-currency conversion. See [Solana integration and live evidence](../OathAnkr/Solana.md).

### Shared history safety

`v28_history_safety` adds contract/network verification and explicit provider block indexes. Every user-facing history projection reads `visibleActivity`, including previews, pagination, search, filter options, transaction counts and details. Filtering runs before the result limit. Raw transactions, receipt archives, balances, UTXOs and sync cursors are retained.

- Native assets remain visible; unlisted token history is hidden unless the user explicitly tracked that contract in that account or disabled **Hide unverified tokens** for that wallet. The latter does not bypass provider blocks, phishing metadata or zero-transfer protection. Matching tickers, logos, prices and unknown on-chain metadata do not grant trust.
- Verification uses Ankr's whitelisted balance responses, the existing chain-specific verified catalogs and exact contract directories for the 17 Advanced API EVM networks. Taiko uses CoinGecko's platform directory because its token-list URL is unavailable. Cached verification survives sold/zero balances and offline startup; migration indexes existing trusted caches.
- Link-based claim bait and zero-value incoming/native or token transfers are hidden. Legitimate zero-value outgoing native contract interactions and recorded outgoing failure/replacement outcomes remain visible. TON's explicit blacklist overrides older verification and manual tracking.
- Keep case-sensitive non-EVM identities intact. Only EVM contracts are lowercased. A catalog's known precision must match the stored asset. Future adapters must persist their verified catalog or verified holdings using the shared database path, and must not use price availability as verification.

Ankr documents `onlyWhitelisted` on `ankr_getAccountBalance`, not on `ankr_getTokenTransfers`. A live check confirmed that sending this undocumented flag to transfers still returned unlisted tokens. Do not rely on an accepted-but-ignored parameter. Reference: [Ankr token methods](https://www.ankr.com/docs/advanced-api/token-methods/).

A listing is not a security guarantee. Small nonzero native payments and transfers of listed tokens can still be malicious; the app does not label all unlisted tokens as fraud or hide every small legitimate payment. Filtering history does not change on-chain balances or spending rules.

`HistorySafetyTests` covers all 31 supported network IDs, migration, cache persistence, user tracking isolation, metadata bait, zero transfers and provider blacklists. `Tools/CheckHistorySafetyLive.py` records read-only public fixtures (credentials stay local). Replay those using `OATH_HISTORY_SAFETY_RESPONSES=/tmp/oath-history-safety-live swift test --package-path Packages/OathDatabase --filter HistorySafetyLiveTests`. It exercises production Ankr decoders and database commits, including TRON receipts; it is separate from UI/device testing.

## Concurrency and consistency

Schema `v56_wallet_default_names` saves a default-name group and ordinal per
wallet. Creation, recovery-phrase import, iCloud restore, and each private-key
network have separate sequences starting with an unnumbered name, then 1, 2,
and so on. Allocation happens in the wallet insertion transaction and includes
recently deleted wallets; reorder, duplicate enrollment, and locale changes do
not renumber existing wallets. Custom names remain literal. Accepting an
unchanged suggested name keeps it automatic so English/Arabic localization
continues to work; chain names are invariant.

Schema `v55_wallet_portfolio_filters` stores the complete asset-filter selection
under a wallet primary key, with a cascading wallet foreign key and reset guards.
New wallets default to hiding unverified tokens. Sorting, asset type, networks,
zero-balance/activity filters, and currency-specific value limits survive wallet
switches and database reopen. Saving emits a new wallet snapshot; canceling a
filter draft performs no write. Value limits are inactive in a different display
currency, rather than reinterpreted as the same amount in that currency.

Token visibility is applied consistently to the existing chain inventories and
Ankr balance rows. Opting in changes visibility, never verification. The app
refreshes unfiltered Ankr holdings in the background; chain-specific adapters
already retain their unverified inventory. Failed or incomplete scans preserve
the previous balances. Deleting or resetting a wallet removes its filters.

All public I/O is asynchronous. Opening/migrations run off the calling actor. GRDB executes SQL on its own queues: up to four reader connections, one serialized writer, WAL mode, foreign keys enabled, and `synchronous=FULL`. Do not weaken durability to improve benchmarks. Do not perform networking or signing inside a database transaction.

`SyncCoordinator` runs independent provider jobs in a bounded task group (default four). A shared permit pool also limits overlapping refreshes; duplicate account/stream jobs are suppressed. Cancellation is checked before committing. An adapter receives a checkpoint and returns a `SyncBatch`. The coordinator assigns its expected cursor/generation and commits the entire page with its new cursor. Screens only observe the resulting database change.

`apply` rejects stale checkpoints and cross-wallet/network records. Old timestamps cannot overwrite newer balances or transactions. Reorg invalidation advances account generations, invalidates affected cached balances/outputs, marks affected history as reorged, and clears cursors. In-flight responses from the previous generation cannot commit. Adapters should use stable, canonical IDs and chain-specific validated values; the database is not a consensus or address validator.

Sync/price/balance batches are limited to 2,000 records. Split larger responses into pages. History, sends, receives, notes, prices, assets, and spendable outputs have bounded queries; use their continuation cursors for subsequent pages. Observations suppress duplicates and retain only the newest pending snapshot.

## Indexes and amounts

- Account lookups: wallet/network and network/address.
- Assets: unique network/reference; symbol index. Portfolio queries visit native assets and existing holdings, not every known token.
- Balances: account/asset primary key and reverse asset lookup. Composite foreign keys prevent joining assets to the wrong network.
- History: wallet/date/ID, account/date/ID, wallet/asset/date/ID, and transaction indexes. Pagination uses a date/ID cursor rather than increasing `OFFSET`.
- Prices: asset/currency/date for the newest quote and historical pages.
- Sends: wallet/date and partial outbox indexes; active nonces are unique by network/sender address, including the same address in multiple wallets.
- UTXOs: one row per chain outpoint, indexed ownership links, available-output and reservation indexes. Input reservation and send-state changes commit together.
- Notes: wallet/date and FTS5 search with transactional triggers; labels use wallet/name and subject indexes.
- Settings and sync cursors: primary-key lookups.

On-chain amounts use validated unsigned decimal **strings of atomic units**, supporting up to 78 digits. They never use `Double` or SQLite `REAL`. UTXO values use checked nonnegative signed 64-bit integers. Prices are validated decimal strings; `Decimal` arithmetic is used only for display valuations, never for signing/spending.

## Sending and receiving

Save a draft, then queue it with either UTXO outpoints or an EVM pending nonce. The writer transaction reserves all inputs or none, and allocates an unused nonce across wallets sharing the sender. Account-based chains without EVM nonces need their own chain-specific signing checks in the adapter.

The durable state machine is `draft → queued → signed → broadcast → confirmed/failed`. Drafts and unsigned queued operations can be cancelled. Signed operations cannot release reservations just because a network request timed out. Broadcast failures/confirmations require matching stored chain state. The shared durable status worker reconciles each enabled send chain using its validated provider receipts. Wallet deletion is rejected while active sends exist.

Receive requests reference a real account/asset and preserve amount/memo/state. Notes and labels validate subject ownership, preventing assignment to another wallet's records.

## Migrations and validation

`v16_tron_ledger` persists active-address TRX/TRC-10/TRC-20 quantities, verification
status, lossless inventories and receipts, and resumable history pages/cursors.
It integrates with portfolio valuation, asset history, public market caches and
wallet-reset fencing. See [TRON integration and live verification](../OathAnkr/Tron.md).

`v5_contacts` adds the app-wide address book without modifying wallet or settings records. Contacts can be created with a name alone, then have network-specific addresses and optional address labels added from their detail screen. Removing the last address keeps the contact. Saves replace the complete address set atomically with the name and search index. Revision checks reject stale editors/deletion confirmations, and foreign keys cascade address removal when a contact is deleted. Search uses an FTS5 prefix index over names, labels, network identifiers/branding, and addresses; network branding updates refresh that derived index. Separate indexes serve name ordering, address display order, and network/address lookup. Stored addresses preserve the original encoding and case; EVM duplicate detection uses a lowercase comparison key.

The app validates addresses using Wallet Core before writing. Mixed-case EVM addresses additionally require an [EIP-55 checksum](https://eips.ethereum.org/EIPS/eip-55). NEAR named/implicit accounts follow the [protocol account-ID rules](https://github.com/near/nearcore/blob/master/docs/DataStructures/Account.md), since the pinned Wallet Core address validator accepts only its implicit/legacy key-derived forms. These are format checks, not network existence or ownership verification. Contacts are local app data, not an import of the device's system address book or part of the recovery-credential iCloud backup.

Schema changes go through `DatabaseMigrator`; never enable destructive migration fallback. `v1_wallet_ledger` is the initial database schema. Add a new migration after this version ships rather than editing an applied migration.

Run the host tests without a simulator:

```sh
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-grdb-validation
```

The suite exercises reopening, wallet isolation, exact amounts, constraints/rollback, pagination, stale responses, observations, reorgs, cancellation, bounded parallel sync, shared nonce/UTXO reservations, notes/search, query plans, and database integrity. iOS integration tests are in `LocalizationTests/OathDatabaseIntegrationTests.swift` and the wallet test suites. Compiling them is separate from executing them; simulator/device execution requires the project's usual authorization.

## Durable send confirmation

`v40_send_status_tracking` enrolls every signed/broadcast send (including existing
journals) in `sendStatusChecks` through SQLite triggers. The indexed `availableAt`
column selects due work without scanning or sorting the entire send history.
Terminal settlement updates history, releases reservations and removes the job
atomically. A transaction moved from confirmed to pending/reorged re-enrolls its
send. Missing provider data and local quote expiry are never proof of failure.

`v47_send_status_available_at` repairs installations that recorded an earlier
v40 table without `availableAt`. It checks `table_xinfo` (generated columns are
absent from `table_info`), adds the missing generated column and replaces the
due index. The existing table, signed payloads, attempts, leases and enrollment/
settlement triggers are preserved. Existing STORED columns stay intact; the
upgrade uses an indexed VIRTUAL column because SQLite cannot add STORED columns
to an existing table ([SQLite generated columns](https://www.sqlite.org/gencol.html)).
The migration runs transactionally before a database is returned to the app.
Failures propagate through the existing shared database-open diagnostics;
there is no destructive reset or silently ignored migration error.

Deadline queries also read `nextAttemptAt` and `leaseUntil` explicitly so GRDB
observes changes to the generated column's dependencies. Reading only
`availableAt` missed lease/retry writes in the host regression. Upgrade tests
reproduce the original missing-column query, preserve journal/queue data, check
index plans and database integrity, reopen twice, and verify deadline observation
and the real status worker on both generated-column forms.

`SendStatusTracker` runs at most four asynchronous checks at a time, backs off
pending/error responses, excludes running jobs even after lease expiry, and has
no arbitrary retry cutoff. Leases recover on a new app process. Task cancellation
keeps unfinished work, and completion cannot recreate a removed job. Deleted
wallets and pending local resets are excluded. Background work is local; wallet
addresses and signed payloads are not uploaded to diagnostics or private backend.

The app's `OathSendStatusTracking` owns foreground activation, a short background
execution window and `BGAppRefreshTask`. iOS chooses refresh opportunities; there
is no promise of continuous execution while suspended or after force-quit. Every
foreground launch resumes pending work, without a screen or an unlocked vault.
No tracking UI or notification is added.

### Adding a send chain

Before enabling another chain in `OathSendModel`, add a case to
`OathTrackedSendChain` and its exhaustive reconciliation switch. The capability
gate keeps unregistered send chains disabled. Journal signed bytes before relay,
use a chain-verified receipt to settle transaction/send records atomically, and
only replay identical authorized bytes. Never sign a replacement in the worker.
Add host tests for restart, pending/offline, final success/failure, expiry or
replacement where supported, cancellation and exact transaction identity. Use
shared `OathDiagnostics` with safe chain/operation context. The SQL triggers enroll
new chain journals automatically; do not add a second polling loop.

Targeted host suites: `SendStatusTrackingTests`, `BitcoinSendSettlementTests`, the
five account-chain `SendJournalTests`, and chain-client send boundary tests.
`SendStatusLiveTests` is opt-in (`OATH_STATUS_LIVE=1`) and uses isolated public
testnet fixtures in `/tmp`. Its test-only database insertion models a crash after
signing; production journal APIs continue rejecting testnet plans. It reopens
the database, recovers an abandoned lease, uses real status clients, and verifies
that final history and removal from the queue survive another reopen. The UTXO
bridge verifies testnet genesis/checkpoints and existing TLS certificate pins.
