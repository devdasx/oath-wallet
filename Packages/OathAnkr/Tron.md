# TRON balances, tokens, prices and history

Implemented and verified with public mainnet reads on October 12, 2026.

## Providers and coverage

TRON is not in ANKR Advanced's EVM account index. The integration uses the
configured ANKR subscription for TRON JSON-RPC and native HTTP node methods:

- `eth_chainId`, batched `eth_call` for TRC-20 quantities and metadata.
- `wallet/getaccount` for liquid TRX in SUN and TRC-10 quantities.
- `wallet/getassetissuebyid` and historic `getassetissuebyname` for TRC-10 identity.
- `wallet/gettransactionbyid`, `gettransactioninfobyid` and
  `walletsolidity/getnowblock` for execution results, transfers and finality.

TronGrid's public account index discovers TRC-20 contracts and supplies three
paginated history streams: direct transactions, token transactions, and internal
transactions. This is necessary because standard node RPC does not enumerate
every contract held by an address or its complete address history. The ANKR key
is only sent to ANKR. Queries contain public addresses, never recovery material.

Balances use the wallet's active TRON account. TRC-20 quantities are read directly
on ANKR; discovery balances are not substituted for contract execution. TRC-10
identities use numeric IDs. Fungible tokens are supported; confirmed TRC-721 NFTs
are excluded. Liquid native balance excludes staked/frozen principal. Staking,
voting and permission changes remain in raw history as native interactions;
this original data integration does not add staking. TRX/TRC-10/TRC-20 sending,
signing, broadcast and Nile verification are documented in [TronSend.md](TronSend.md).

CoinGecko-listed tokens are automatically visible, matching the app's existing
verified-token policy. Explicitly added custom tokens remain visible. Other
discovered fungible holdings are retained in the database but hidden from the
portfolio and its total. A market listing is not a guarantee of token safety.

## Prices and cache

TRX uses Coinbase's USD spot endpoint, with wrapped-TRX market data as fallback.
Token quotes are matched by exact TRON contract/ID, never symbol:

1. DEX Screener, choosing the deepest positive-liquidity matching base-token pair.
2. GeckoTerminal's contract-price endpoint.
3. CoinGecko's contract-price endpoint, also supporting legacy TRC-10 IDs.

All quotes store their USD value, provider and timestamp. Display currency uses
the existing exchange-rate cache. CoinGecko's network directory supplies names,
symbols, decimals and logos; blockchain decimals must agree before catalog
metadata can mark a token verified. Token information, inventory, history and
market data persist in SQLite for offline reads. A failed or missing quote does
not overwrite a cached price with zero. Tokens without a real quoted market
cannot be given a reliable price; no provider guarantees prices for every token.

## Concurrency, failures and history

Independent inventory, directory, native quote and history jobs overlap. ANKR
requests share four permits; contract balance batches contain twenty calls with
three batch workers. Receipt and metadata work is bounded as well. Batch IDs,
errors, exact amounts, account identity and network identity are validated.
One reverting token is isolated from healthy batch members.

The anonymous TronGrid tier was observed enforcing one request per second and
a five-second suspension after exceeding it. Index calls therefore share one
permit, start at least 1.1 seconds apart, and retry throttling with 6/12-second
backoff. Free market fallbacks are paced separately. Removing these limits or
launching unlimited requests would increase failures rather than improve speed.

Each history stream has a recent window and an older backfill window. The recent
window includes non-solid transactions; solid block height determines confirmed
state. It overlaps one day on subsequent refreshes. Backfill has no artificial
transaction-count cutoff. Fingerprints retain their original query window and
advance only with an atomic page/receipt commit. Expired fingerprints restart
the same window once; repeated cursors fail safely. Large histories arrive
progressively and resume from disk after interruption.

Receipts determine successful execution. A zero return word from a successful
TRON USDT call does not invalidate its real Transfer event. Reverts produce no
successful transfers. The decoder handles native sends, TRC-10 transfers,
TRC-20 logs and internal TRX/TRC-10 calls. Stable receipt indexes deduplicate
transactions returned by multiple streams. A solid receipt replaces tentative
events, including events removed by failed execution. Full response JSON is
retained losslessly, including fields not projected into the current UI.

Discovery failure leaves old token balances intact while still allowing healthy
native/TRC-10 reads. Individual token failures retain that token's last value.
Incomplete pages cannot advance history. Concurrent refreshes coalesce. Lock,
wallet changes and reset cancel work; generation/run checks reject stale writes.
Reset removes private account inventory/history, retaining public price caches
and app settings.

Schema `v16_tron_ledger` adds `tronSync`, `tronHoldings`, `tronHistoryCursors`,
`tronTransactions` and `tronPages`. Portfolio balances, asset history and USD
valuation use the shared observable ledger. Home and asset pull-to-refresh invoke
the synchronizer; historical downloads continue independently of balance refresh.

## Verification performed

Public wallets used (no private keys, signing or transfers):

| Address | Exact fungible balances | Tronscan rows | Listed token holdings priced |
| --- | ---: | ---: | ---: |
| `TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh` | 96 | 72 | 4 |
| `TQguVRm3tDmZG7AeZ47Mk6qi6GTF1ZDqkZ` | 71 | 63 | 2 |
| `TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb` | 584 | 471 | 18 |

These are point-in-time results: **751 balances, 606 explorer rows and 24 priced
holdings**. Inventories were compared with TronGrid and Tronscan's public account
API. Some nonstandard unverified contracts had stale indexed amounts; every such
discrepancy was checked against an independent TronGrid `balanceOf` execution
and matched ANKR. One ERC165-confirmed NFT was excluded from fungible balances.
Tronscan's combined `tokens` array omits some holdings, so row counts differ.

Separate numerical quote checks compared JST, WIN, USDT and BTTOLD with Tronscan's
TRX-denominated price converted to USD. Differences were 1.15%, 2.22%, 0.22% and
0.34%, respectively. Coinbase TRX was $0.3304001783 and CoinGecko $0.329986 at
sampling time. Prices come from different markets/timestamps and are not expected
to be identical.

All three history streams were checked through first and continuation pages,
plus matching ANKR transaction receipts. A production synchronizer/database run
on `TUoHaVjx7n5xz8LwPRDckgFrDWhMhuSuJM` downloaded all five transactions, completed
all six history cursors, and retained five activities, balance and price after
reopening SQLite. These checks do not claim to have downloaded the entire
lifetime history of the three larger wallets.

Host tests cover exact uint256 quantities, checksums, malformed responses,
failed execution, NFT exclusion, historic TRC-10 identity, solid-block finality,
batch ID matching, partial discovery, cached values, offline reopening, whitelist
visibility, wallet isolation, duplicate events, cursor replay/loops, pending
receipt replacement, reset fencing and stale responses. Existing API/database,
wallet-session and receive tests were also run. The iOS app compiled for a generic
device destination. No simulator, physical device or visual runtime check was run.

Run the host suites from the repository root:

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-tron-api-tests
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-tron-db-tests
```

Live tests are opt-in with `OATH_LIVE_TRON_KEY` (inventory/history),
`OATH_LIVE_TRON_COMPARE_KEY` (three-wallet comparisons),
`OATH_LIVE_TRON_DATABASE_KEY` (complete small-account history), or
`OATH_LIVE_TRON_PRICES=1` (keyless price comparisons). Load credentials from the
ignored local configuration without printing them. Run TronGrid live suites
sequentially to respect the shared public rate limit. Checked-in JSON fixtures
contain public mainnet responses only.

## Primary references

- [ANKR TRON APIs](https://www.ankr.com/docs/rpc-service/chains/chains-api/tron/)
- [TRON node and index APIs](https://developers.tron.network/docs/api)
- [TronGrid address transactions](https://developers.tron.network/reference/get-transaction-info-by-account-address)
- [TronGrid token transactions](https://developers.tron.network/reference/get-trc20-transaction-info-by-account-address)
- [TronGrid internal transactions](https://developers.tron.network/reference/get-internal-transactions-by-address)
- [TRON internal transaction receipts](https://developers.tron.network/docs/internal-transactions)
- [Tronscan account token API](https://docs.tronscan.org/en/api/account/account-tokens)
- [CoinGecko contract prices](https://docs.coingecko.com/reference/simple-token-price)
- [DEX Screener API](https://docs.dexscreener.com/api/reference)
