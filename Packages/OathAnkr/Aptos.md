# Aptos accounts, Coins and fungible assets

Balance/history integration implemented October 12, 2026. Sending was added
October 14; see [Aptos sending and verification](AptosSend.md) for fee, signing,
broadcast, recovery and live testnet evidence.

## Providers

- ANKR Aptos REST mainnet supplies ledger identity, exact native/Coin/FA balances,
  object ownership and full transaction receipts. A live `ankr_getAccountBalance` probe explicitly rejected `aptos` as an
  unsupported blockchain for the Advanced account methods.
- The Aptos Labs indexer supplies owned asset/store discovery and account activity,
  including incoming transfers. Sender-only full-node account transactions are
  insufficient for wallet history. This is also the API used by Aptos Explorer.
- Pruned receipts fall back to the official Aptos archive; ordinary node errors
  can fall back to the official full node. Fallback hosts are fixed and never
  receive the ANKR credential.
- Coinbase supplies native APT/USD. Panora supplies contract-keyed Coin/FA quotes,
  metadata and verified-token aliases. Its documented public client access key
  is intentionally public; attribution is retained as `Powered by Panora`.
- DEX Screener supplies missing contract quotes in batches of at most 30. Only
  exact Aptos base-token matches with at least USD 1,000 reported pool liquidity
  qualify; the deepest qualifying pool is selected.

A token without an available market cannot have a genuine quote invented for it.
Missing quotes retain the last successful cache entry and its observation time.
Names/symbols never determine price identity. The existing app currency conversion
continues to consume USD prices.

## Execution and accounting

Up to four node reads and two price batches run concurrently. Native pricing and catalog refresh overlap inventory. History starts after
inventory is committed, so it cannot consume the shared index quota first.
History advances in five-transaction pages with parallel receipt reads. Indexer queries are
paced and serialized. They already return multiple balances/events in one
request. ANKR Aptos `/transactions/batch` is a write/submission API and is never
used as a read batching mechanism.

Native APT uses `coin::balance<AptosCoin>`. A migrated Coin's balance includes its
paired primary FA store, so that store is not added again. Non-primary FA stores
are separately checked for owner and metadata identity before their balance is
added. FA reads use the protocol's dispatch-aware balance getter. Amounts remain
integer strings throughout decoding and persistence, including values above the
exact range of floating-point numbers.

Discovery pages use `(asset_type, storage_id)` keyset ordering. Node balance
reads are pinned to one ledger version. Discovery is eventually consistent with
that node snapshot, not a cross-service atomic snapshot. Failed, lagging or
incomplete discovery cannot clear the previous token inventory. Per-token read
failures preserve saved amounts. Canonical identity collisions are rejected
rather than silently overwriting balances. The public Panora verified list
controls automatic token visibility; raw holdings remain stored, and the
existing explicit tracking policy is preserved.

Account history pages use descending transaction versions. Full node receipts
verify version, execution status, hash, exact gas cost and indexed deposit/
withdraw event amounts. Both old Coin event handles, generic Coin module events
and FA events are recognized. Failed transactions retain their receipt and gas;
failed transfers do not become successful movements. Counterparties are not
invented from multi-party swap events. Full receipt/index records retain fields
not projected into the current UI, including gas sponsorship and storage refunds.
The displayed fee field is gross `gas_used * gas_unit_price`.

## SQLite and app integration

Migration v18 adds `aptosSync`, `aptosHoldings`, `aptosHistoryCursors`,
`aptosTransactions` and `aptosPages`. Account foreign keys and reset guards match
the other network ledgers. On-chain Coin/FA aliases are retained in the public
market cache, including after a balance reaches zero, so migrated token history
stays together even when that token is not in the verified catalog. Raw history pages and their cursor commit together;
recent-history catch-up and old-history backfill survive restarts. Repeated pages
upsert stable transaction/event IDs. Generation tickets reject results after
wallet replacement, reset or a newer refresh.

The active wallet refresh, portfolio/total, asset prices, asset activity and
receive guidance use the new ledger. Token information and USD prices use the
existing public market cache, independently from wallet-specific raw responses.
Reset deletes Aptos account/history records and preserves public market caches.

## Public endpoint limitations

Live testing observed HTTP 408 timeouts for inventory queries on three public
accounts, followed by HTTP 429 against the anonymous compute quota.
Other funded accounts returned successfully through the same production query.
The app does not turn those failures into a zero balance or erase saved tokens.
An indexer timeout/rate limit starts a five-minute cooldown instead of repeatedly
spending the quota on retries; later refreshes resume persisted history cursors.

For higher indexed-account capacity, the existing ignored
`OathApp/Private/TokenRPC.plist` accepts optional `AptosIndexerAPIKey` alongside
`AnkrAPIKey`. It is sent only as a bearer credential to the official indexer.
No Aptos indexer key was created or purchased for this implementation.

## References

- [ANKR Aptos REST API](https://www.ankr.com/docs/rpc-service/chains/chains-api/aptos/)
- [Aptos indexer](https://aptos.guide/build/indexer/indexer-api)
- [Indexer tables](https://aptos.guide/build/indexer/indexer-api/indexer-reference)
- [Aptos Coin/FA migration](https://aptos.guide/build/smart-contracts/fungible-asset)
- [Aptos framework source](https://github.com/aptos-labs/aptos-core/tree/main/aptos-move/framework/aptos-framework/sources)
- [Explorer account query](https://github.com/aptos-labs/explorer/blob/main/app/api/hooks/useGetAccountCoins.ts)
- [Panora token directory](https://github.com/PanoraExchange/Aptos-Tokens)
- [Panora prices](https://docs.panora.exchange/developer/token-prices)
- [DEX Screener API](https://docs.dexscreener.com/api/reference)

## Validation evidence and boundaries

- Production Swift client on public account
  `0x041972b6755d06cc9129ab6b6a772aaca1061c8585ef3c15bddbc144bd05a63c`:
  **3 balances** (APT, USDC and wrapped SOL) matched independent Aptos Labs node
  reads at the same ledger version. First and continuation history requests
  succeeded and receipts were checked. Panora returned two available quotes for
  these three identities; an unavailable quote was not invented.
- The production synchronizer committed **5 transactions** and **2 visible
  verified holdings** for that account. Balances and prices survived reopening
  SQLite. The unverified holding was retained outside the automatic portfolio.
  This test deliberately stops after a committed page; it does not claim to
  download the account's entire lifetime history.
- APT Coinbase/Panora price comparison passed a 5% cross-venue tolerance.
  DEX Screener's USDC quote was positive and within 10% of USD 1. A separate live
  30-identity Panora batch returned **26 positive quotes**; four unpriced assets
  were excluded, not assigned a fabricated price.
- ANKR's Advanced account API returned `aptos is not allowed`. Three other public
  inventory queries returned HTTP 408; follow-up requests, including an additional
  account test, were limited with HTTP 429. Broader funded-account parity remains
  **unverified**. An appropriately provisioned Aptos indexer is needed before
  claiming reliable coverage for all account sizes. The code supports an optional
  local indexer credential but none was supplied during this task.
- Host regression suites cover exact integer amounts, owner/store checks,
  primary/secondary stores, paired Coin/FA double-count prevention, archived
  receipt fallback without credential forwarding, real mainnet event fixtures,
  old/generic events, verified identity matching, missing quotes, persisted
  migration aliases, history cursors, stale writes, reset, and offline metadata.
  The shared-indexer ordering regression ensures balances commit before history.
- OathAnkr, OathDatabase and OathMarketData host suites pass. Opt-in unrelated
  network tests are skipped in those offline runs. Receive checks and production
  wallet host checks passed. The generic iOS build passes. No simulator, physical
  device, UI visual check, signing, or broadcast was performed.

Repeat the opt-in client test with `python3 Tools/CheckAptosLive.py --run`.
Add `--database` for the production synchronizer/SQLite test, or `--owners` with
comma-separated public accounts. Credentials are loaded from the ignored local
configuration and redacted from test output. Avoid repeatedly retrying the
anonymous endpoint during its compute-limit cooldown.
