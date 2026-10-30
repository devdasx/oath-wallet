# XRP Ledger account integration

For sending, signing, broadcast recovery, and public Testnet evidence, see
[XRP Ledger sending](XrplSend.md). The inventory verification below describes the
earlier read-only integration.

## Scope and providers

The active classic XRP address is read through ANKR's authenticated `xrp_mainnet` standard RPC endpoint. The public `xrplcluster.com` endpoint provides failure fallback. This is not an ANKR Advanced API integration: use XRP's native account and ledger methods, not EVM balance endpoints.

- `ledger`, `account_info`: validated ledger and exact XRP drops.
- `account_lines`: every trust-line page, retaining signed balances and all authorization/freeze/limit flags.
- `account_objects(type: mptoken)`, `ledger_entry(mpt_issuance:)`: MPT holdings and on-chain metadata/asset scale. Empty filtered pages with a marker must still be traversed.
- `account_tx`: native and issued/MPT token activity, fees, status, tags, memos and original metadata. All response pages are retained. Native and token changes come from validated `AffectedNodes`, never a requested Payment amount, which is unsafe for partial payments.

State reads are pinned to one validated ledger hash. Independent discovery, history and market reads overlap; RPC work has a six-request permit pool. The tested ANKR HTTP JSON-RPC array request returned HTTP 503, so production uses bounded concurrent individual calls and native server pagination. Coinbase/CoinGecko prices are fetched in parallel with balances; CoinGecko quotes are batched up to 30 identities. Missing token quotes use bounded DEX Screener requests with exact currency/issuer identity and at least $1,000 pool liquidity. No address or secret is sent to price providers.

Coinbase supplies XRP/USD. CoinGecko's `xrp` platform catalog maps currency+issuer to market IDs; DEX Screener's `xrpl` market is a fallback. Ticker matching and assumed stablecoin pegs are prohibited. No service can supply a genuine USD market price for a token with no market. Missing/failed quotes preserve prior cached prices and their timestamps; they do not create a zero price. Unverified tokens remain stored but hidden under the app's existing catalog-or-explicitly-tracked visibility rule.

## Amounts and persistence

Classic issued currencies use a signed 16-digit mantissa and exponent, not fixed ERC-20-style decimals. The adapter stores them losslessly at an **internal scale of 96**, with a bounded 193-digit integer capacity (including delta carry). The UI does not label this internal scale as token decimals. XRP uses six decimals; MPTs use their issuance's `AssetScale`. Signed liabilities are retained in the inventory and `signedAmount`; they never become positive portfolio assets. Reserve/flags remain available in the original account snapshot; the send client separately reads fresh ledger state before signing.

Migration `v21_xrpl_ledger` adds account-scoped inventories, balances, validated transaction details, original response pages and persistent recent/backfill cursors. Complete inventory commits clear spent/removed holdings atomically. Incomplete/failed reads leave the saved inventory intact. History persists an inclusive upper ledger with each marker. Expired markers restart with overlap at the oldest saved ledger, preserving other transactions in that ledger. Older history runs independently of the first visible balance refresh. Per-run tickets reject old-wallet/old-refresh writes; cancellation and reset erase account data while keeping settings and market caches.

MPT metadata failures retain raw balances and unresolved history for later projection. Confidential MPT encrypted balances cannot be decrypted by a public read-only RPC integration; public `MPTAmount` is preserved along with any encrypted/locked fields in the raw record. NFTs are not fungible holdings. Historical availability ultimately depends on the providers; a pruned account history range is rejected rather than marked complete.

## Verification on 2026-10-12

Host-only checks, no simulator or physical-device execution:

- Four public addresses compared using the actual Swift client at validated ledger **107596608**, against independent `xrplcluster.com` reads. All exact inventory entries matched: **25, 7, 36, 23** (including XRP). The fourth address has **21 MPT holdings**. Twenty recent transactions per address matched, and following pages had no duplicate hashes.
- Addresses: `r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59`, `rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q`, `rHJ57KNiiPtwiqpmhJRzRYUEmFTkrkEebC`, `rsiPEXNs1XGn14DV7MHXsTfQVpGiEpJ347`.
- Independent XRPSCAN read-only comparison matched native XRP and **24, 6, 35** trust lines for the first three accounts. XRPSCAN is a test comparison only, not a production provider.
- Coinbase vs CoinGecko XRP/USD and CoinGecko vs DEX Screener RLUSD/USD agreed within the 5% live-feed tolerance. The catalog returned 36 canonical identities including native XRP. This verifies those quotes, not universal market coverage.
- Production synchronizer test persisted **7 holdings and 431 transactions** in a temporary database. Reopening the database reproduced the same portfolio and prices offline. No user wallet was imported, signed, or sent from.
- Unit coverage includes checksum/case-sensitive issuer identity, smallest/largest issued amounts, negative liabilities, partial payments, fee separation, low/high trust-line perspective, filtered pagination, pruned/repeated history rejection, concurrency/fallback/cancellation, stale writes, wallet isolation, reset, cached metadata and exact-issuer price rejection.

Re-run public network tests with `python3 Tools/CheckXrplLive.py --run --database`. Credentials are loaded from the ignored local RPC plist into the subprocess environment, with output redaction. Tests use public addresses only. Network and unit tests do not guarantee every external provider will always be available.

## Protocol references

- [ANKR XRP account API](https://www.ankr.com/docs/rpc-service/chains/chains-api/xrp/account/)
- [XRPL account_lines](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/account-methods/account_lines)
- [XRPL account_tx](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/account-methods/account_tx)
- [XRPL currency amounts](https://xrpl.org/docs/references/protocol/data-types/currency-formats)
- [MPToken ledger object](https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/mptoken)
- [MPTokenIssuance ledger object](https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/mptokenissuance)
