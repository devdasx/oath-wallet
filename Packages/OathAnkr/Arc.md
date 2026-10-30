# Arc mainnet balances, tokens, prices, and history

Implemented for mainnet chain **5042**, checked on 2026-10-12. Testnet 5042002
is never used as a fallback. This is a read-only portfolio integration; it does
not add signing, broadcasting, or an NFT portfolio.

## USDC identity

Arc's native asset is USDC with 18 atomic decimals. The ERC-20 interface at
`0x3600000000000000000000000000000000000000` exposes the same funds with six
decimals. The app keeps one native USDC asset, maps imports of that contract to
it, and verifies `floor(nativeAtomic / 10^12) == balanceOf(owner)` at the same
block. Values stay integer strings, including sub-micro-USDC dust.

Native history uses EIP-7708 `Transfer` events from
`0xfffffffffffffffffffffffffffffffffffffffe`. The six-decimal USDC mirror is
excluded, with a matching native-event check to detect missing system events.
Equal transfers with different log indices remain distinct. Fees use receipt
`gasUsed * effectiveGasPrice`, in native USDC units, separately from transfers.

## State, discovery, and persistence

- `ArcClient` pins native and ERC-20 state to one block, verifies chain identity
  on every batch, correlates response IDs, and checks the block hash again.
  Batches contain up to six token state/metadata reads and run three at a time,
  alongside the native read. A malformed or failed read never becomes zero.
- Contract metadata comes from onchain `name`, `symbol`, and `decimals`.
  Optional missing labels fall back to the contract identifier; a missing
  precision remains an incomplete read.
- A refreshed/cached CoinGecko Arc contract catalog bootstraps discovery.
  An 86-contract public identity snapshot provides first-load coverage during
  catalog outages. It contains no balances or prices and is **not all tokens**.
  Previously discovered and explicitly added contracts are also queried.
- Envio HyperSync provides address-filtered ERC-20/native events and direct
  transactions. Independent recent and genesis lanes persist exact block
  cursors. Each page, events, transactions, and cursor commit atomically.
  Page-discovered contracts are subsequently read from RPC, not valued by
  summing transfer logs. Failed/zero-value calls remain in activity.
- Schema v24 adds `arcSync`, `arcHoldings`, `arcHistoryCursors`, `arcEvents`,
  and `arcPages`. Portfolio and asset-history reads use the existing observed
  database. Wallet changes/reset cancel requests and invalidate stale writes.
  Reset deletes Arc wallet data while retaining public market caches.
- Automatic display retains the app's CoinGecko-listed-token filter.
  Explicitly added tokens can be shown without listing. A listed token is not
  a safety endorsement. Unknown tokens can be persisted without appearing
  automatically in the portfolio.

## Prices and outages

Native USDC uses Coinbase's `USDC-USD` spot quote. ERC-20 prices use exact Arc
contract mappings to CoinGecko IDs, then missing quotes fall back to DefiLlama,
GeckoTerminal's Arc contract endpoint, and DEX Screener. Requests are batched
in groups of 30; independent groups run in parallel. Quotes never match by
ticker and never assume that a stablecoin is worth $1.

CoinGecko/DefiLlama timestamps must be recent, DefiLlama confidence must be at
least 0.9, and the DEX Screener fallback requires at least $10,000 liquidity.
The most recent successful quote is cached with its source/time and retained
on API failures. Some arbitrary tokens have no reliable price; this is not
converted into a fabricated quote. Display currency continues to use the
existing USD exchange-rate cache.

## Current access limitation

Real probes found that ANKR's available Advanced registry does not include
Arc. The official Blockdaemon mainnet RPC handles current state and recent
logs, but rejects pruned historical ranges. The other tested official public
RPCs returned access errors on balance requests. Endpoint failover is coded,
but there is currently only one live-verified accessible state provider.

Envio serves Arc archive queries, but `/query` rejects anonymous access (401).
Complete token auto-discovery/history therefore requires an Envio API token.
The index adapter is implemented and fixture-tested, but **its live query and
complete archive coverage are unverified until a token is configured**.
Missing credentials leave history incomplete rather than storing empty success.
Receive guidance does not promise automatic discovery without configuration.

Create a token at <https://app.envio.dev/api-tokens>, then run:

```sh
python3 Tools/ConfigureTokenRPC.py --provider envio
```

The hidden prompt writes `EnvioAPIKey` to the ignored local
`OathApp/Private/TokenRPC.plist`; existing credentials are preserved. Rebuild
to include it. Credentials are never stored in SQL responses or test fixtures.

## Verification

Host checks (no simulator/device) covered precise units, USDC canonicalization,
shuffled batches, chain mismatch, fallback, reverts, block mismatch, dual
emitters, duplicate logs, incomplete history, cursor progress, quote fallback,
stale quotes, persistence, wallet isolation, reset, and offline portfolio reads.

Public mainnet checks used three addresses observed in public Arc events:

- `0xd55273357eb916e62e7b23114312989dfee4a3db`: four nonzero catalog tokens,
  four live USD quotes.
- `0x8f10b468b06c6fd214b65f87778827f7d113f996`: 75 nonzero catalog tokens,
  75 live USD quotes. Includes small/dust holdings; count is not portfolio value.
- `0xa4072583658fae592a3506a42431cb6316a8d40b`: no nonzero catalog tokens at
  the observed block; this does not prove absence of uncatalogued holdings.

The production database sync saved 76 holdings (including native USDC), all
with USD quotes, then reopened offline with identical holdings and total.
These are live RPC/API checks, not an independent explorer comparison or a
claim of complete token discovery. Envio's authenticated live test was skipped.

```sh
swift test --package-path Packages/OathAnkr
swift test --package-path Packages/OathDatabase
OATH_ARC_LIVE=1 OATH_ANKR_CONFIG="$(pwd)/OathApp/Private/TokenRPC.plist" \
  swift test --package-path Packages/OathAnkr --filter ArcTests
OATH_ARC_LIVE=1 swift test --package-path Packages/OathDatabase --filter ArcLedgerTests
```

API rates and holdings change; assertions target valid live state and usable
quotes, rather than hardcoding mutable balances. A rate-limited catalog uses
the bundled identities; the test reports that fallback explicitly.

## Primary references

- [Arc wallet integration and USDC semantics](https://www.arc.io/blog/supporting-arc-in-wallets-one-balance-usdc-fees-and-complete-history)
- [Arc system events](https://docs.arc.io/arc/references/usdc-system-events)
- [Envio Arc indexing](https://docs.envio.dev/blog/index-arc-usdc-transfers)
- [HyperSync query schema](https://docs.envio.dev/docs/HyperSync/hypersync-query)

Generic iOS compilation, host package tests, host wallet integration, and
receive/QR checks passed. Runtime, visual, simulator, physical-device, and
broadcast checks were not performed.

Recorded runs: OathAnkr 128 tests (17 skipped, zero failures; Arc balances live),
OathDatabase 192 tests (16 opt-in tests skipped, zero failures), plus all eight
Arc database tests with the production live-sync opt-in enabled. The host wallet
integration reported 439 checks, and the receive/QR tool reported 1,943 checks.
