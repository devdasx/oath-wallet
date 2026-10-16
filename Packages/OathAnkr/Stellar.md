# Stellar balances, tokens, and activity

Stellar sending was added on October 14, 2026. See [StellarSend.md](StellarSend.md)
for its implementation, Testnet transaction evidence, and verification boundaries.

Implemented and verified with read-only public mainnet calls on October 12, 2026.
No wallet secrets, signatures, transaction submission, simulator, or physical
device were used for these checks.

## Data sources

- ANKR Advanced API at the configured authenticated multichain endpoint:
  `stellar_getAccountBalance`, `stellar_getEvents`, `stellar_getTokenPrice`.
  These use `blockchain: stellar_soroban`; the ordinary EVM `ankr_*` registry
  does not include Stellar.
- ANKR Horizon at `https://rpc.ankr.com/http/stellar_horizon` reads mainnet
  classic account/trustline balances. SDF Horizon is the fallback.
- ANKR Soroban `simulateTransaction` reads `name`, `symbol`, and `decimals`
  from historical tokens whose metadata is no longer in the current holdings.
  Envelopes are unsigned, contain no authorization, and are never submitted.
- Coinbase provides XLM/USD. CoinGecko's keyless catalogue/price API maps
  exact Stellar contract or code-and-issuer identities, never ticker matches.
- For eligible classic assets lacking an aggregator quote, SDF Horizon's
  trade aggregations provide a 24-hour volume-weighted XLM price, converted
  using the current XLM/USD quote. Require at least 100 XLM volume, three
  trades, a trade bucket within two hours, and an XLM quote within one hour.

References: [ANKR Stellar API](https://www.ankr.com/docs/api-reference/aapi/stellar-soroban-api/),
[Stellar Asset Contract](https://developers.stellar.org/docs/tokens/stellar-asset-contract),
[Unified Asset Events (CAP-67)](https://github.com/stellar/stellar-protocol/blob/master/core/cap-0067.md),
[token interface](https://developers.stellar.org/docs/tokens/token-interface),
[XDR schema](https://github.com/stellar/stellar-xdr/blob/main/Stellar-contract.x),
[Horizon API](https://developers.stellar.org/docs/data/apis/horizon/api-reference).

## Correctness and persistence

The active wallet account supplies the G-address. Independent inventory,
history streams, native price, and catalogue requests overlap. Network work
uses bounded concurrency (six ANKR requests); quotes use two concurrent
30-token batches. Cursor pages within a stream stay sequential.

The indexed token list is insufficient on its own: one tested public account
had 380 classic holdings while ANKR indexed 331. The client merges complete
Horizon trustlines with contract-only SEP-41 balances. A classic asset and its
Soroban wrapper use the same deterministic mainnet contract identity and are
never added twice. Removed trustlines cannot be resurrected by an older index.
Raw quantities remain exact integer strings, including non-seven-decimal
contract tokens. No balances pass through floating point.

Unfiltered discovery is persisted for completeness. Automatic portfolio
visibility requires ANKR's whitelist or an exact CoinGecko catalogue identity;
manually tracked assets remain visible. History alone cannot make an
unverified token reappear. Token discovery is not a safety endorsement.

Schema `v22_stellar_ledger` adds account-scoped inventory, holdings, events,
history cursors, transaction projections, and raw response pages. Existing
asset, price, market-cache, portfolio, and activity tables serve the UI.
Completed inventory replaces holdings atomically. Failed/incomplete reads
preserve the last successful values. Raw snapshots include provider prices,
totals, sync state, liabilities, authorization, and other unprojected fields.

Two persisted history streams prioritize the recent 518,400 ledgers while
backfilling the earlier archive from ledger 1. Events cover transfers, mint,
burn, clawback, and fees. Decoding includes legacy administrator topics,
memo/muxed amount maps, fee refunds, claimable-balance and pool counterparties.
Transaction amounts are net changes per asset; fees are separate. A transaction
split between pages is reprojected from its saved event set. Unknown token
metadata keeps the raw event for later projection instead of guessing decimals.
An explicit `events: null` is ANKR's terminal-page form; a missing field or
an index behind the requested ledger remains a failure.

Repeated refreshes coalesce. Wallet changes/lock/reset cancel work, and run IDs
reject late account writes. Reset erases wallet-owned Stellar records while
retaining public market caches. A slower quote cannot overwrite a newer quote
or cause an otherwise successful balance refresh to fail.

## Verification

Host tests cover identity/checksums, issuer matching, exact quantities, merging,
contract-only tokens, wrong-owner rejection, malformed/repeated pages, null
terminal pages, memo transfers, legacy mint, fee refunds, stale responses,
unverified-token filtering, wallet isolation, offline reopening, and reset.

Live production Swift tests compared four public accounts against independent
SDF Horizon: 2, 3, 380, and 5 classic holdings. The fourth also contained a
contract-only Comet token (6 total holdings). A separate read-only Soroban
`balance(Address)` simulation matched its indexed amount exactly. See
[Comet's published deployment](https://docs-v1.blend.capital/mainnet-deployments).

The comparison script matched nine sampled transactions against Horizon's
credit/debit effects across three accounts. Live checks also validated an
unfunded account, historical-token metadata, disjoint continuation pages,
Coinbase/ANKR XLM quotes, exact-contract CoinGecko USDC/XLM quotes, and a real
KALE price from the DEX fallback. Prices/balances are point-in-time observations.

The production database test saved holdings and thousands of events, cancelled
the larger backfill, and reopened an identical offline portfolio. Separately,
both streams for a smaller account exhausted their cursors with 34 archived
events. The large account's entire history was not downloaded in that test.

Run the repeatable read-only checks using the ignored local ANKR configuration:

```sh
python3 Tools/CheckStellarLive.py --run --swift
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-solana-ankr-build --build-system native
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-token-database-build --build-system native
swift test --package-path Packages/OathMarketData --scratch-path /tmp/oath-market-data-tests --build-system native
```

App compilation uses a generic iOS destination with signing disabled. UI,
simulator, and physical-device behavior were not tested in this task.

## Coverage limits

Tokens without a real listed or sufficiently liquid market cannot have a
reliable USD price. Preserve an older quote when available; never infer USD
value from a matching symbol or treat a failed quote as a successful zero.
Quotes carry their actual source and timestamp.

Balances include available classic trustlines and indexed SEP-41 holdings;
liquidity-pool share positions remain in the raw account response, not mislabeled
as fungible token balances. NFTs, pending mempool activity, DeFi position
valuation, and non-transfer administrative transaction history are outside this
integration. Classic account reserves/liabilities are retained, but this work
does not calculate a sendable amount or add Stellar signing/broadcast.
History completeness is bounded by ANKR's index. Provider failures and unknown
metadata remain resumable, not falsely marked complete.
