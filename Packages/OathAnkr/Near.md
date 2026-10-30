# NEAR balances, fungible tokens, prices, and history

NEAR and NEP-141 sending is documented in [NearSend.md](NearSend.md), including
fee reservations, vault authorization, durable recovery and live testnet evidence.

Implemented and checked with public mainnet reads on October 12, 2026.

## Providers and concurrency

ANKR NEAR RPC is the primary source for finalized on-chain account state,
NEP-141 balances, and NEP-148 token metadata. The existing ignored local RPC
configuration supplies its credential. The official NEAR mainnet RPC is a
fallback for transient HTTP/connection failures; credentials are never sent to
the fallback. Mainnet is checked and all state queries in an inventory use the
same finalized block hash and validate the returned block hash and height.

The live ANKR endpoint rejected JSON-RPC array batches with HTTP 400. NEAR state
reads therefore use bounded parallel individual queries, sharing six permits
across inventory and history. FastNear transaction-detail requests use actual
batches of up to 20 hashes, in parallel. CoinGecko quotes use up to two parallel
batches of 30 identities. Dependent pagination remains sequential.

Standard NEAR RPC does not enumerate every token held by an account or index
all incoming/outgoing account history. FastNear's public token index supplies
contract discovery; its transfers and account-transaction APIs supply history.
These keyless endpoints worked in live testing. Their future availability and
rate limits are outside the app's control; failures retain persisted data and
resumable progress.

Primary references:
[ANKR NEAR RPC](https://www.ankr.com/docs/rpc-service/chains/chains-api/near/access-keys/),
[NEAR contract queries](https://docs.near.org/api/rpc/contracts),
[NEAR batching](https://docs.near.org/api/rpc/batching),
[FastNear account discovery](https://github.com/fastnear/fastnear-api-server-rs),
[FastNear transfers](https://docs.fastnear.com/transfers),
[FastNear transaction API](https://tx.main.fastnear.com/).

## Exact account and token state

- Queries use the active stored NEAR account. Both named and implicit account
  identifiers are accepted. This does not discover other named accounts that
  happen to share a key, or change the wallet's existing derivation/import flow.
- Native balance is the account's liquid plus locked NEAR, with both components
  and storage usage saved separately. It is not an assertion that locked funds
  are spendable. Delegated staking-pool positions and NFTs are outside this
  fungible account ledger.
- Discovery is combined with previously known and explicitly tracked contracts.
  Each contract's balance is read from `ft_balance_of` at the pinned block.
  Indexer quantities are retained for comparison, not trusted as current state.
- Amounts remain decimal integer strings, including 24-decimal NEAR amounts and
  values beyond binary floating-point precision. Decimals come from on-chain
  metadata and are never guessed from symbols.
- One broken contract does not discard the other successful balances. A failed
  read preserves the previous value and observation time. A successful zero
  clears the old amount. A never-successful read remains unknown internally.
- Missing metadata preserves raw units; cached metadata remains usable.
  Unresolved historical events are projected when metadata later arrives.
- All discovered holdings are stored. Automatic portfolio display follows the
  app's unverified-token policy using exact CoinGecko-listed contract identities;
  explicitly tracked assets remain eligible. Listing is not a safety guarantee.

## History

Transfer effects and transaction execution history are independent streams.
Transfer effects cover native NEAR and NEP-141 fungible tokens, including incoming
effects. Execution records retain fees, success/failure, actions, receipts, and
logs from the complete returned transaction JSON. Failed executions are shown
as failed, not converted into successful payments. Native execution placeholders
are removed when the real native transfer effects arrive.

Opaque cursors and per-block transfer indexes preserve distinct effects in the
same block. Recent and older-history cursors commit with their data atomically,
resume after interruption, and deduplicate by account/event or transaction
identity. A newer run, account change, or reset prevents an old run from writing.

Some indexed transfer effects have no transaction hash. Their receipt identity
is retained rather than inventing a transaction hash. Unknown newer asset
standards, such as NEP-245 internal multi-token positions, remain in raw history
without assigning invented NEP-141 identities or decimals. Indexer coverage
defines the available historical range; this is not a guarantee of independent
archival reconstruction of every NEAR receipt.

## USD prices and persistence

Coinbase supplies NEAR/USD. CoinGecko's `near-protocol` directory maps exact
contracts to quote identities. Intear's public bulk NEAR token-price endpoint is
the fallback, matched by contract and validated against on-chain decimals.
Ticker-only matching is never used. CoinGecko timestamps must be recent; Intear
does not provide a quote timestamp in this response, so its cache records fetch
time rather than claiming an exchange observation time. Invalid, missing, or
zero quotes do not erase a cached real quote. Tokens without a published market
can remain unpriced; genuine prices cannot be guaranteed for every token.

[CoinGecko identity directory](https://docs.coingecko.com/reference/coins-list),
[CoinGecko USD quotes](https://docs.coingecko.com/reference/simple-price),
[Intear token indexer](https://docs.intear.tech/docs/token-indexer/).

Schema v20 adds account-scoped holdings, sync state, transfer effects, full
transaction details, raw history pages, and resumable cursors. Public metadata
and USD quotes use the shared market cache. Portfolio totals, currency
conversion, sorting, asset details, receive guidance, lock cancellation, and
wallet reset use the existing app infrastructure. Reset deletes private
account/history state while retaining public metadata and prices. No signing or
broadcasting was added.

## Actual verification

Live read-only production-client results:

| Public account | Contracts discovered | Successful pinned balance reads | Failed contract reads retained as unknown/cached |
| --- | ---: | ---: | ---: |
| root.near | 169 | 165 | 4 |
| mob.near | 94 | 91 | 3 |
| here.tg | 8 | 6 | 2 |

Native liquid/locked values matched the official RPC at identical finalized
blocks for all three accounts. Twenty-eight contract balances were independently
compared, including every non-null indexer discrepancy and a sample of nonzero
holdings. All 28 matched the second RPC. Most indexed balances matched directly;
the differences demonstrate why discovery quantities are not used as final
balances. This test does not claim independent comparison of every contract.

Each account returned native transfer and execution pages; older transfer pages
had no overlapping event IDs. Recent root.near transaction hashes overlapped
NearBlocks' independently fetched account history. NEP-141 transfer decoding
also uses captured real wrapped-NEAR history.

Live price checks returned 25 CoinGecko quotes and 95 Intear quotes across the
tested nonzero holdings. Wrapped NEAR, USDT, and REF contract-price comparisons
agreed within 15%; native Coinbase/CoinGecko quotes agreed within 10%. These are
test tolerances for independently cached feeds, not a promise of identical
prices or proof that every quote is liquid.

The production synchronizer wrote a fresh database for here.tg: three visible
holdings, 100 transfer effects, and 50 executions were present at the checkpoint
before cancellation. Reopening the database without fetching matched the stored
portfolio. The test intentionally stopped after committed history pages; it did
not download these active accounts' entire lifetime histories.

Deterministic host tests cover precision, missing accounts, contract failures,
block/network validation, cached metadata, quote identity, stale quotes,
bounded concurrency, cancellation, credential-safe fallback, account isolation,
history continuation, same-block boundaries, reset fences, and offline reopening.

Repeat live tests with `python3 Tools/CheckNearLive.py --run --database`.
`--run --database-only` repeats only the persistence test. The tool loads the
credential locally and redacts it from output. Package tests, the host wallet
harness, and a generic iOS compile do not launch the app. No simulator, physical
device, visual inspection, or live transfer was used for this task.
