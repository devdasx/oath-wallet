# Gram (TON) accounts and Jettons

Implemented and checked against public mainnet data on October 12, 2026.
The app displays **Gram / GRAM** and retains the `ton` network identifier, native
9-decimal units and existing wallet derivation. Provider routes such as Coinbase's
`TON-USD` still use the historical ticker.

## Providers and execution

- **ANKR TON API v2:** `getMasterchainInfo`, `getAddressInformation`,
  `getTokenData` and `runGetMethod`. Mainnet genesis is checked against TON's
  official configuration. Native and Jetton amounts remain exact integer strings.
- **TonAPI:** paginated account Jetton inventory, low-level native transactions,
  Jetton transfer/mint/burn operations, verification, names, logos, descriptions
  and contract-keyed USD quotes. This supplies indexing beyond ANKR node reads.
- **Coinbase:** native GRAM spot quote using the provider's `TON-USD` identity.
  TonAPI's native `GRAM` rate is the fallback.
- **DEX Screener:** missing Jetton quotes, batched by up to 30 master contracts.
  Only exact mainnet base-token identities match; the most liquid pool with at
  least USD 1,000 of reported liquidity is used. Quotes are never inferred from
  a ticker, the opposite side of a pair, or a fixed stablecoin peg.

Live ANKR probes returned HTTP 500 for JSON batch arrays and `getTransactions`
(JSON-RPC and HTTP routes). Consequently the app uses four bounded concurrent
node calls, rather than repeatedly submitting unsupported batches. Inventory,
quotes and history run as independent tasks. The shared anonymous TonAPI client
paces index requests at least 4.2 seconds apart, per its published rate allowance.
HTTP 429 and transient server/transport errors receive bounded retries.

No service can return a real price for a token without an available market.
Missing/zero quotes do not overwrite a successful cached quote or become a
fabricated USD price. Source and observation time accompany saved prices.

## Identity and state safety

Friendly bounceable/non-bounceable addresses normalize to one raw identity after
CRC validation; testnet friendly addresses are rejected. Jetton balance reads
use the discovered Jetton wallet and verify its reported owner and master. The
master's `get_wallet_address` getter must independently return that wallet.
This prevents an arbitrary contract merely reporting a plausible owner/master
from supplying a wallet balance.

TonAPI's `whitelist` classification controls automatic portfolio visibility.
All discovered holdings are retained, including hidden unverified ones; explicitly
tracked assets remain available under the existing manual-token policy. A quote
by itself does not verify a token. Failed individual reads retain their previous
balances. Only complete successful discovery can zero an absent holding.

History uses indexed protocol operations, not heuristic account-event summaries
or a reconstruction of balances. Native inbound value is retained even when a
compute phase fails; the transaction's failure and actual fee are also retained.
Raw provider records, fees, message bodies and Jetton payloads remain in SQLite.
Token event identities are stable across metadata changes and page overlap.
Jetton pages overlap their boundary logical time so simultaneous operations in
different wallets are not skipped. A non-advancing cursor fails without committing.

## Persistence and app integration

Schema v17 adds `tonSync`, `tonHoldings`, `tonHistoryCursors`, `tonTransactions`
and `tonPages`, with account foreign keys, reset guards and compound indexes.
Each history page and cursor commit atomically. Recent history catches up to its
previous high-water mark; historical loading resumes from its persisted boundary.
The initial recent page seeds historical loading without fetching it twice.
A previously empty wallet subsequently gaining multiple pages is handled too.

Run tickets fence stale results after another refresh, account replacement or
reset. Locking/resetting cancels outstanding account work. Public token metadata
and USD price caches are separate from wallet-specific raw responses. Wallet
reset removes account/history data while retaining public market caches, as with
other supported networks. Legacy cached TON balances remain readable until the
new ledger replaces them.

The shared portfolio, total balance, asset detail prices, paged activity,
receive guidance and refresh coordinator now consume this ledger. The asset
information screen reads cached Jetton names, logos and descriptions without
another index request. Existing USD-to-local-currency conversion and asset
sorting remain shared with the other chains.

## Validation evidence

Production Swift client, read-only mainnet tests against three public accounts:

| Public account | Native + Jetton balances matched | Independent Jetton wallets | Verified-token TonAPI USD quotes |
| --- | ---: | ---: | ---: |
| `0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3` | 49 | 48 | 19 |
| `0:f8b8635d0786b77f9da660e65fd31d670a675dd4302facba692f46b571eb5360` | 142 | 141 | 32 |
| `0:8afbcb163358eb20be1ae9b610a2938038d84a1087e7f49cccbf8046f59c859f` | 3 | 2 | 1 |

All **194 amounts** matched: ANKR native balances versus TonAPI account state,
and all nonzero Jetton holdings versus the independent Toncenter v3 index.
Hidden tokens were included in the comparison. Zero-wallet inventory differences
between indexers do not imply a balance difference.

First and continuation pages were read for native and Jetton history on all
three accounts. The first account's five native hashes/fees and five Jetton
movements were also independently matched against Toncenter. Jetton comparisons
use the trace, master, sender, recipient and amount: sending and receiving
transactions in one asynchronous TON transfer have different hashes.

A production synchronizer/database test downloaded the smaller account's complete
history: **76 distinct transactions, 49 native activities and 31 USDT activities**.
All four recent/backfill cursors completed. Balances and USD prices survived a
SQLite reopen. These counts are point-in-time evidence, not fixed network facts.

Independent price comparisons covered native GRAM (Coinbase versus TonAPI) and
USDT, DOGS and NOT (TonAPI versus DEX Screener). Observed differences were below
1%; tests allow 5% for sampling different venues/times. This does not establish a
price for every possible Jetton or complete history for the two large accounts.

Host regression coverage includes address aliases/checksums/mainnet, large exact
integers, wallet ownership binding, incomplete inventory pages, failed individual
reads, whitelist visibility, mint/burn and failed native execution, repeated
logical times, stable event IDs, cursor persistence, newly active wallets,
deduplication, wallet isolation, stale writes, reset fencing and offline metadata.
The complete OathAnkr, OathDatabase and OathMarketData host suites and the generic
iOS application build passed. Receive and production multiwallet host checks
passed as well. No simulator, physical device, UI visual test, signing or
broadcast was performed.

Live tests are opt-in with `OATH_LIVE_TON_KEY` for the client and
`OATH_LIVE_TON_DATABASE_KEY` for the production database integration. Set these
from the ignored local RPC configuration without printing credentials or placing
them on a command line. Fixture files contain only public chain responses.

## Primary references

- [TON branding](https://ton.org/media/)
- [ANKR TON methods](https://www.ankr.com/docs/rpc-service/chains/chains-api/ton/methods/)
- [TON mainnet configuration](https://ton.org/global-config.json)
- [TON address formats](https://docs.ton.org/foundations/addresses/formats)
- [Jetton standard, TEP-74](https://github.com/ton-blockchain/TEPs/blob/master/text/0074-jettons-standard.md)
- [TonAPI access and rate limits](https://docs.tonapi.io/tonapi)
- [TonAPI Jetton methods](https://docs.tonapi.io/tonapi/rest-api/jettons)
- [TonAPI rates](https://docs.tonapi.io/tonapi/rest-api/rates)
- [TonAPI schemas](https://github.com/tonkeeper/opentonapi/blob/master/api/openapi.yml)
- [Toncenter v3 independent index](https://toncenter.com/api/v3/)
- [DEX Screener API](https://docs.dexscreener.com/api/reference)
