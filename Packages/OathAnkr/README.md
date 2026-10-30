# Ankr account balances and history

Current release: [4.1.15 (99) verification record](../../releases/4.1.15.md). Historical checks below describe their original scope; they are not an independent audit of this release.


Implemented and checked against public mainnet responses on October 11, 2026.

## Coverage

The multichain account API registry includes **17 EVM mainnets**:
Ethereum, Arbitrum, Avalanche C-Chain, Base, BNB Smart Chain, Fantom,
Flare, Gnosis, Linea, Optimism, Polygon, Scroll, Somnia, Story, Taiko,
Telos EVM, and X Layer. The API aliases `eth`, `bsc`, `somnia_mainnet`, and
`story_mainnet` map explicitly to the app's network identifiers.

This registry is specific to the Advanced account methods. Ordinary Ankr RPC
support does not imply Advanced account indexing support. Testnets are excluded.
Bitcoin, Bitcoin Cash, Dogecoin, and Litecoin continue using their existing
Electrum ledgers. Solana uses the separate standard-RPC integration described in
[Solana.md](Solana.md). TRON uses ANKR node RPC plus TronGrid's address index,
described in [Tron.md](Tron.md). Gram (TON) uses ANKR node verification with
TonAPI Jetton/history indexing, described in [Ton.md](Ton.md).
Aptos uses ANKR REST plus the Aptos account indexer and contract-keyed prices,
described in [Aptos.md](Aptos.md).
Sui uses ANKR GraphQL with checkpoint-pinned balances, token metadata, and
paginated transaction effects; see [Sui.md](Sui.md).
NEAR uses finalized ANKR account/token state with FastNear discovery and history,
plus contract-keyed USD prices and resumable persistence; see [Near.md](Near.md).
Arc, TRON, TON, and the remaining non-EVM networks do not acquire
balance fetching from the Advanced account methods.
Arc uses its official mainnet RPC, native-USDC canonicalization, contract-keyed
prices, and an optional Envio archive index; see [Arc.md](Arc.md) for the
implemented behavior, live checks, and the outstanding index credential.

Stellar uses its separate `stellar_*` Advanced API namespace, ANKR Horizon,
and Soroban metadata reads. Live probes confirmed archived unified classic
and contract transfer events, including older synthetic events. Classic
trustlines supplement incomplete indexed inventories; see [Stellar.md](Stellar.md)
for exact coverage, price fallbacks, persistence, and verification.

Primary references:

- [Advanced API overview](https://www.ankr.com/docs/advanced-api/overview/)
- [Token methods](https://www.ankr.com/docs/advanced-api/token-methods/)
- [Query methods](https://www.ankr.com/docs/advanced-api/query-methods/)
- [Query API reference](https://www.ankr.com/docs/api-reference/aapi/query-api/)
- [Separate Stellar API](https://www.ankr.com/docs/api-reference/aapi/stellar-soroban-api/)
- [Gateway error and retry policy](https://www.ankr.com/docs/rpc-service/errors/retry-strategies/)

## Data and behavior

`ankr_getAccountBalance` retrieves native and ERC-20 holdings with
`onlyWhitelisted: true` on every page by default. Ankr defines this filter as tokens listed
on CoinGecko; it is not a guarantee that a token is safe. Exact integer amounts never pass through
floating point. The app saves token identity, decimals, logos, unit price, token
USD balance, account USD total, count, and provider synchronization status.
Display-currency conversion uses the existing USD exchange-rate cache.

With **Hide unverified tokens** enabled, only automatically discovered holdings
from a successful filtered inventory appear in the portfolio and its total.
Disabling this per-wallet preference requests `onlyWhitelisted: false` on every
balance page, alongside a separate filtered inventory. Both must complete before
the atomic commit; only tokens in the filtered inventory receive whitelist
evidence. Re-enabling the preference immediately hides cached unverified tokens.
The background refresh uses the existing bounded request pool and waits for any
older balance flight before reading the saved preference again.

Schema v12 marks old unfiltered Ankr
inventories as ineligible for automatic display until a whitelist refresh
succeeds, including when the app is offline. Native balances remain visible.
A complete refresh retires excluded token balances atomically; partial or failed
refreshes preserve the last filtered inventory. History alone cannot add a token
back to the portfolio. Metadata, market quotes and transaction history are kept.
Explicitly added custom tokens remain the user's choice; when omitted by the
filtered API, their balance is unknown rather than persisted as a successful zero.

`ankr_getTransactionsByAddress` retrieves direct transactions with receipt logs,
decoded calls, and decoded logs requested. `ankr_getTokenTransfers` retrieves
ERC-20 events, identified by network, transaction, log index, and asset. Native
activity, token events, failures, timestamps, block data, and execution fees are
projected into the existing ledger. A token event cannot erase a richer receipt.

Every successful JSON-RPC response is also saved **byte for byte**, including
properties not projected into UI models: input, signatures, nonce, receipt
logs, decoded data, chain-specific fees, and future fields. Balance archives
replace the previous complete inventory; history archives persist by query
window and page. The database offers paged archive metadata, individual raw
responses, typed asset details, and observable portfolio/history reads.

Balances, direct history, token history, and networks run independently with a
shared maximum of four network requests. Cursor pages are sequential within a
stream. Completed pages commit atomically with their continuation cursor. A
restart resumes that window; an expired cursor restarts it once with idempotent
upserts. Incremental history overlaps one day and respects the provider's
indexed timestamp. Missing/reorged events are reconciled only after a complete
window. Long histories update the visible database while downloading.

HTTP throttling, documented transient JSON-RPC errors, and server/transport failures retry with bounded
backoff. Failed, truncated, mismatched, or incomplete inventories cannot clear
saved balances. Overlapping refreshes coalesce. Lock, wallet changes, and reset
cancel outstanding work; generation/run checks prevent stale writes. Reset
removes account responses and history while preserving existing market caches
and app settings.

New full EVM wallets include Fantom, Flare, Somnia, and Story. Existing full EVM
wallets reuse their established public Ethereum derivation for those networks.
Deliberately narrower imported-key scopes remain unchanged. Each new network
has bundled native artwork; its Receive screen uses the existing explanation
fallback rather than an unverified illustrative token list.

## Observed provider behavior

- Some balance responses ignore `pageSize`. Before whitelist filtering, one public
  BNB account returned 12,280 assets. The transport allows a bounded 64 MiB response, and the importer
  requires a complete inventory before retiring old holdings.
- Unpriced tokens return empty price/USD strings. Their exact quantities remain
  visible when included in the whitelist; a missing price does not replace an existing cached quote.
- Native entries use the zero contract address. Native branding remains local:
  a live Flare response incorrectly labeled FLR as Ether/ETH.
- Fantom returned `outOfSync`. The UI exposes delayed indexing and retains the
  last usable data. Successful HTTP transport alone is not a freshness claim.
- `ankr_getBlockchainStats` is restricted for the configured account. Network
  coverage uses an explicit, documented and live-tested registry instead.
- The APIs do not guarantee mempool visibility or a complete list of internal
  native-value calls. Full internal traces and NFT portfolios are not claimed
  by this integration. Raw receipt logs remain preserved. Send/sign/broadcast
  remain outside this work.

## Validation

Host tests cover all 17 response schemas, exact large amounts, multi-page
completion, repeated/expired cursors, partial failure, retries, concurrent
refreshes, cancellation, delayed indexers, wallet isolation, migration from
schema v10/v11, whitelist filtering on every page, cached-token removal,
reset fencing, and original-response retention.

Live read-only tests use a published exchange address on all 17 mainnets, two
additional public addresses on five major networks, and active public accounts
on Flare, Somnia, Story, Linea, Taiko, and Telos. Continuation pages are checked
when returned. A production synchronizer test completes all three streams on
three mainnets. The initial unfiltered response captures replay through the production client
and SQLite for schema coverage, including over 20,000 holdings; those historical
fixtures do not establish whitelist membership. These checks do not claim to download
every historical transaction of the large exchange accounts.

The whitelist follow-up was checked live on all 17 mainnets. On the same public
account, a direct filtered/unfiltered comparison reduced Ethereum from 2,039 to
413 assets and Base from 4,075 to 94; filtered contract sets were subsets of the
unfiltered inventories. These are point-in-time counts, not fixed expectations.
The v11 migration, failed/partial refresh, manual additions, wallet isolation,
and history-resurrection regressions pass in the host database tests.

Offline checks:

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-ankr-tests
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-ankr-db-tests
```

Live checks are opt-in using `OATH_ANKR_LIVE=1` and `OATH_ANKR_CONFIG` pointing
to the ignored local RPC plist. Never put the API key or a credential-bearing
URL in command output. `Tools/ProbeAnkrAdvanced.py` writes public response
fixtures outside the repository; `OATH_ANKR_RESPONSES` enables their database
round-trip test. Checked-in fixtures are explicitly trimmed public samples.

The iOS app is compiled for a generic device destination without installing or
launching it. Simulator, physical-device, visual, and transaction-broadcast
checks are not part of this validation.

## XRP Ledger

See [XRP Ledger integration and verification](Xrpl.md) for validated account state, issued currencies, MPTs, history, provider fallback and exact-identity pricing.

## THORChain sending

The shared send flow supports RUNE and transferable bank denominations, including
TCY and RUJI. Amounts use exact integers; protocol assets use eight decimals and
other denominations require verified bank metadata. Transfers use THORChain's
`/types.MsgSend`, secp256k1 and Cosmos `SIGN_MODE_DIRECT`. This is a payment
integration, not a swap, deposit, staking or contract-execution interface.

Independent quote reads run concurrently with bounded requests. The quote checks
chain identity, account sequence, balances, destination, metadata, halt state and
the current native transaction fee. Fees are paid in RUNE, including token sends.
The quote guard is not an encoded on-chain fee cap: THORChain deducts its protocol
fee at execution, and confirmed history records the actual fee.

The vault authorizes the exact persisted plan. SQLite journals the signed bytes
before broadcast. A successful CheckTx returns submission immediately; the shared
durable status worker resumes after reopening and verifies inclusion, execution
failure, replacement or expiry. Retries reuse the same bytes. Balance refreshes
require inventory at or above the committed block height.

Verification on 2026-10-15:

- Eight independent WalletCore 4.8.4 signing vectors matched byte for byte.
- Host send, journal/restart, authorization/lock, diagnostics and targeted shared
  tracking tests passed; the generic iOS build passed.
- Official THORNode 3.20.0 ran an isolated mocknet (`oath-thorchain-test-1`). Real
  RUNE, TCY, RUJI and six-decimal test-token transfers passed, with exact recipient
  credits and sender fee deductions. Duplicate submission, committed replacement,
  execution failure and unused-transaction expiry were checked.
- A mainnet quote and preflight passed using public account data, without signing
  or broadcasting. Simulator/device UI and mainnet transfers were not tested.

[Public stagenet is discontinued](https://docs.rujira.network/developers/developer-endpoints).
The transaction checks above are isolated-chain evidence, not public-testnet claims.
`Tools/PrepareThorchainLocalFixture.cjs` creates a disposable node from a pinned
official image and writes new test-only keys outside the repository. Set its
documented SDK environment variables, then use its fixture path with
`OATH_THORCHAIN_SEND_FIXTURE` to run `ThorchainSendLiveTests`. Do not use app wallets
or mainnet funds. The helper refuses to overwrite an existing test container;
stop that named container after testing. Public read-only testing is separately
enabled with `OATH_THORCHAIN_SEND_MAINNET_READ=1`.

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-thor-send-spm --filter ThorchainSendTests
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-thor-send-db --filter 'Thorchain|SendStatusTracking|PostSendBalanceRefresh|WalletReset'
OATH_VALIDATION_SCRATCH=/tmp/oath-thor-vault-host python3 Tools/CheckMultiWallet.py --thorchain-send
```
