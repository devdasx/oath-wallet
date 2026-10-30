# Solana balances, tokens, prices and history

Implemented and checked on October 12, 2026. This is read-only wallet data;
it does not implement Solana sending, signing, staking positions or NFT displays.

## Providers

- Paid Ankr Solana RPC reads SOL and both SPL Token and Token-2022 inventories
  in a three-member JSON-RPC batch. Amounts remain exact atomic-unit strings;
  multiple token accounts are aggregated by the case-sensitive mint address.
- Mainnet genesis is verified before accepting data. Complete inventories alone
  may replace balances; failed requests retain saved values. Frozen token
  accounts remain part of owned balances.
- Ankr documents about 16 hours of Solana history retention. Live checks confirmed
  empty signature results and null old transactions for an older public wallet.
  Signature enumeration therefore uses the official Solana mainnet archive,
  with Ankr for transaction batches and archive fallback for missing transactions.
  A recent-only fallback cannot mark old history complete.
- Archive calls use smaller batches, shared pacing, adaptive throttling and
  bounded backoff. HTTP 200 batches can contain individual RPC 429 errors;
  retries preserve successful members and retry only failed IDs. Balances,
  prices and database reads need not wait for historical backfill.
- SOL/USD comes from Coinbase, with a wrapped-SOL market fallback. Token prices
  use exact mint addresses at DEX Screener (deepest positive-liquidity pool),
  then GeckoTerminal for missing quotes. Calls batch up to 30 mints and run with
  bounded parallelism. Price source and fetch date are stored with each quote.
- CoinGecko's Solana list supplies names, symbols, precision, logos and the
  listing filter. Listing does not certify safety. All discovered token accounts
  are cached; automatic display preserves the existing policy of hiding unlisted
  tokens. Explicit custom-token additions remain visible.

Source documentation:

- [Ankr Solana and retention](https://www.ankr.com/docs/rpc-service/chains/chains-api/solana/)
- [Solana token accounts](https://solana.com/docs/rpc/http/gettokenaccountsbyowner)
- [Solana signature pagination](https://solana.com/docs/rpc/http/getsignaturesforaddress)
- [Public endpoint limits](https://solana.com/docs/references/clusters)
- [DEX Screener batch pricing](https://docs.dexscreener.com/api/reference)
- [GeckoTerminal API](https://api.geckoterminal.com/docs/index.html)
- [CoinGecko Solana list](https://tokens.coingecko.com/solana/all.json)
- [Coinbase SOL/USD](https://api.coinbase.com/v2/prices/SOL-USD/spot)

## Persistence and active address

Schema `v15_solana_ledger` adds `solanaSync`, `solanaHoldings`,
`solanaHistoryCursors`, `solanaTransactions` and `solanaActivity`. It retains
inventory and transaction content, exact quantities, frozen-account state,
durable history cursors and internal failure state. Quotes use the shared USD
price table and market cache; display currency uses existing FX rates.

Phantom/Trust selection determines the address being queried and displayed.
Each address has separate balances, history and cursors. Generation and run IDs
reject responses from previous selections, including switching A to B to A.
Receive QR/copy/share, portfolio and open asset detail follow the selection.
Lock, wallet changes and reset cancel work; reset removes wallet data while
preserving price caches and settings.

History follows the owner and its token accounts, including token deposits whose
transaction does not name the owner directly. Closed accounts discovered in older
transactions remain watched. Pages commit with their cursor, deduplicate shared
signatures, and resume after interruption. Balance deltas produce native/token
activity; execution fees are separate and failed transactions never invent
transferred amounts. Fee-only native activity is labeled as a transaction.

Very old transactions without token-owner metadata are retained but do not receive
guessed token movements. A null/missing archived transaction keeps its page
incomplete. Unsupported future transaction versions likewise cannot advance a
cursor. Stake accounts, DeFi positions, compressed NFTs and program-specific
action decoding are outside this balance integration.

## Live evidence

Only public explorer addresses were used; no mnemonic/private key was imported
and no transaction was signed or broadcast. Opt-in tests compare every raw token
account, mint, amount, decimal count and frozen flag against the independent
official RPC, as well as exact SOL lamports. Point-in-time observations:

| Public wallet | SOL | Token accounts | Listed nonzero mints with prices |
| --- | ---: | ---: | ---: |
| [H31v…QoU](https://solscan.io/account/H31vEBxSJk1nQdUN11qZgZyhScyShhscKhvhZZU3dQoU) | 278.330661366 | 7,260 | 12/12 |
| [3yFw…BDy1E](https://solscan.io/account/3yFwqXBfZY4jBVUafQ1YEXw189y2dN3V5KQq9uzBDy1E) | 1.129298094 | 280 | 12/12 |
| [CutA…1Qeom](https://solscan.io/account/CutAG7TzyTq6BNECcvLjm2FCxL19pPPQDqV2em91Qeom) | 0.016685999 | 6 | 4/4 |

Counts change as wallets receive more assets. These tests included 7,051
Token-2022 accounts. GeckoTerminal supplied three quotes missing from DEX
Screener. Exact balances matched the independent RPC for all 7,546 accounts.
Solscan's visible SOL balances and sampled USDC, JUP, SOLCAT, ACS, MBS, BAKED and
GUMMY quantities matched, allowing for display rounding.

The price comparison was close, not exact. Saved DEX quotes included ACS
$0.0001557 and BAKED $0.0001215; Solscan displayed $0.0001561 and $0.0001206 at
comparison time. Providers use different markets/timestamps. Solscan includes
stake positions in overall net worth and has a different token visibility policy;
that headline total is not the liquid SOL/token total. No API guarantees a price
for tokens without quoted markets. Missing prices do not overwrite cached quotes
or persist fabricated zero prices.

An end-to-end host test runs the production synchronizer and temporary SQLite
database for CutA…1Qeom. It completes all seven owner/token-account archive
cursors, persists 29 distinct historical transactions, verifies native and token
activity, and reopens the database. Live throttling occurred and recovered.
Other live tests check token-account activity on all three wallets and distinct
archival continuation pages. They do not download the entire history of the
large exchange wallet.

The final targeted API run passed 11 deterministic tests and three live tests.
The host database suite passed 122 tests, with seven opt-in tests skipped;
the live Solana database check was run separately and passed. A final targeted
database rerun passed eight Solana tests, with its live test skipped. The
existing wallet/session harness passed 437 checks, and receive guidance/QR
validation passed 1,937 checks. The generic iOS build succeeded.

## Repeating validation

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-solana-ankr-build
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-token-database-build
```

`SolanaLiveTests` and
`SolanaLedgerTests.testLiveSolanaSyncPersistsCompletePublicWalletHistory` are
opt-in using `OATH_LIVE_SOLANA_KEY`. Supply it locally from the ignored RPC
configuration; never print it or put a credential-bearing URL in logs. Do not run
archive-heavy live suites simultaneously: the public endpoint shares IP limits.

Host suites cover large exact amounts, both token programs, frozen balances,
whitelist behavior, address/wallet isolation, stale responses, pagination,
cancellation, cursor promotion during parallel discovery, retries, offline caches,
reset cleanup and database reopening. The iOS app was compiled for a generic
destination. Simulator/device runtime and visual checks were deliberately not run
under the project's code-first policy.
