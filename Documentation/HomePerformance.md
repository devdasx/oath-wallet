# Home live-data performance

Validated 2026-10-16. This change retains live database observation, persisted
balances, transaction history, wallet isolation and privacy filtering. It does
not defer writes, introduce a second database, or wait for a refresh to finish
before publishing new data.

## Causes and fixes

1. **The scroll container defeated lazy rows.** A UIKit scroll view measured a
   full-height SwiftUI hosting controller. In an isolated 500-row probe, all 500
   rows were constructed and ten value changes caused 5,000 body evaluations.
   `OathNativeRefresh` now uses SwiftUI `ScrollView` and `.refreshable`. Its small
   attachment observes public UIKit geometry without replacing SwiftUI's scroll
   delegate, gestures or content host. The existing Oath indicator and haptics
   remain. With the production Home header layout, only six rows were initially
   constructed; scrolling realized more rows as needed.
2. **Unrelated writes invalidated the Home root.** The root observed the entire
   wallet snapshot, including provider checkpoints. An isolated child now feeds
   the existing background presentation builder. Home observes separate display
   properties, and `balancesHidden` changes only when that setting changes.
   Currency, filter, wallet and actual balance changes still update immediately.
3. **History ordering could not use the existing timestamp index.** Reads sorted
   a joined `COALESCE(outcomeAt,timestamp)` expression. Migration v58 adds the
   equivalent persisted `sortTimestamp` and wallet/asset/account/network indexes.
   Triggers maintain it in the source write transaction, including evidence
   replacement, deletion and rollbacks. History paging uses this ordered index;
   the regression checks that SQLite does not create a temporary ordering tree.
4. **History safety repeated text analysis for every read.** Asset metadata
   safety is computed when metadata changes and stored as a projection. The
   existing visibility rules and per-wallet opt-in remain in `visibleActivity`.
   Updating metadata immediately reindexes safety; no transactions are erased.
5. **Balance reads included other wallets' ledgers.** The effective-holdings
   query now scopes every chain-ledger branch to the requested wallet's accounts
   before aggregation. All chain-specific verification/tracking rules remain.
6. **Some foreign-key lookups lacked an index.** The migration audits every
   table in `OathDatabase`, reuses suitable full indexes/primary keys, and indexes
   uncovered child relationships. A partial index does not count as coverage.
   Indexes target actual query and relationship access; adding an index to every
   field would increase writes and storage without making these reads faster.

This extends the existing native SQLite/GRDB and Swift packages. No additional
third-party package or custom asynchronous indexing service is needed.

Migration backfills run before the database pool is published. An interrupted
wallet reset remains pending through migration; the activity reset guard is
restored in the same transaction. Failed migration work rolls back atomically.
Existing database failure boundaries continue through `OathDiagnostics`; the
coverage baseline/exclusions were not expanded for this work.

## Measured evidence

The database fixture contains four synthetic wallets, 1,000 token holdings and
20,000 activity rows (5,000 for the queried wallet). Values below are medians of
eight host reads, not physical-device frame-time measurements.

| Check | Before | After |
| --- | ---: | ---: |
| Wallet snapshot | 81.59 ms | 22.55 ms |
| First 51 history rows | 71.59 ms | 3.22 ms |
| Missing foreign-key index prefixes | Not audited | 0 |
| Initially realized rows, 500-row runtime fixture | 500 | 6 with Home header |

The host stress check committed 40 successive balance writes while observing the
wallet and reading history. All 40 were persisted; the observer delivered the
correct final value with 39 deliveries (the existing latest-value observation
can coalesce intermediate emissions). Its concurrent main-actor heartbeat had
a maximum interval of 3.10 ms. This is a host scheduling measurement, not an iPhone
frame-rate guarantee.

The isolated iOS 27 simulator probe exercised the production scroll package and
Home header layout using synthetic rows. It checked native scroll callbacks,
realization of newly visible rows, system refresh completion and branded refresh
completion. It used programmatic UIKit scrolling/control activation, not manual
touch gestures or a user's wallet. It did not launch Oath or contact providers.
The temporary simulator was removed after the check.

## Validation and repeatable checks

- Generic iOS app build with signing disabled.
- OathDatabase host suite: 457 tests, 43 opt-in tests skipped, zero failures.
- OathDiagnostics host suite: 52 tests, two opt-in tests skipped, zero failures.
- Final migration/reset regression: seven tests passed, including upgrade from
  v57 with a pending wallet reset and restoration of the write guard.
- `Tools/CheckHomePortfolio.py`: formatting/cache, timestamp-only updates,
  filters/currency/wallet changes, cancellation and progressive chain updates.
  A 5,000-row background presentation build left the main actor responsive.
- Refresh host checks: 6,181 lifecycle/vector checks, 20,000 repeated idle stops
  without observation notifications, and asynchronous cancellation/ownership/
  diagnostic privacy tests passed.
- `Tools/CheckDiagnosticsCoverage.py`: 474 catch sites, coverage guard passed.

Run the deterministic index regression on the host:

```sh
swift test --package-path Packages/OathDatabase --filter HomeReadIndexTests
```

Run the opt-in synthetic benchmark and concurrent writer/observer check:

```sh
OATH_HOME_BENCHMARK=1 swift test --package-path Packages/OathDatabase --filter HomeIndexPerformanceTests
python3 Tools/CheckHomePortfolio.py
```

`Tools/CheckHomeScrollRuntime.py` preserves the runtime fixture. Under AGENTS.md,
run it only for a specific unresolved runtime concern, with the explicit
`--simulator-check --output /tmp/oath-home-scroll-result.json` arguments. It
requires XcodeGen and an installed iOS simulator runtime and creates/deletes
only its own simulator. The archived evidence is
`output/home-performance-validation-2026-10-16.json`.

No physical device, full-app runtime, user wallet or live-provider performance
test was performed for this change. A guarantee of zero lag on every device is
not supported by these measurements; the demonstrated unnecessary work has
been removed and the regressions above guard it.
