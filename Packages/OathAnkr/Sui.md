# Sui balances, tokens, prices, and history

Implemented and verified with public mainnet reads on October 12, 2026.

## Provider and protocol

- ANKR Premium GraphQL is the primary provider. The existing locally configured ANKR credential is read from the ignored application configuration, never from source.
- The official Sui mainnet GraphQL endpoint is a bounded fallback for transient HTTP failures. Credentials are never forwarded to it.
- Every response is checked against the mainnet chain identifier. GraphQL errors, including partial-data errors returned with HTTP 200, are failures.
- This integration does not depend on deprecated Sui JSON-RPC. Sui's Foundation mainnet JSON-RPC shutdown and planned October removal make that unsuitable for new code.
- At most four chain requests run concurrently. Inventory, history, and public market work overlap; pagination stays sequential where the next cursor depends on the previous response.

Primary documentation:
[ANKR Sui GraphQL](https://www.ankr.com/docs/rpc-service/chains/chains-api/sui/graphql/),
[ANKR corrected Premium URL](https://www.ankr.com/docs/changelog/premium-http-keyed-urls-2026-10-07/),
[Sui migration cookbook](https://www.docs.sui.io/develop/accessing-data/graphql/graphql-migration-cookbook).

## Balances and metadata

All balance pages are pinned to the same checkpoint. The totalBalance field includes both coinBalance and addressBalance; their exact integer sum is validated. One tested account holds all native SUI in address balances, so coin-object-only discovery would have missed its SUI.

Canonical identities preserve case-sensitive Move module/type names and normalize only hexadecimal addresses, including nested generic arguments. Token prices and metadata never match by ticker alone. Raw quantities remain decimal integer strings throughout storage.

Metadata uses separate GraphQL alias batches of eight, up to four in parallel. Live ANKR and official endpoints enforce a 21-backing-store-query budget; putting many metadata objects inside a balances query produced RESOURCE_EXHAUSTED, even though the HTTP status was 200. Separating the queries fixed that failure. Valid metadata and explicit null results are cached briefly in memory. Public metadata is also saved in the database for offline use.

A missing or deleted metadata object cannot establish decimals. Such holdings retain their exact type, amount, both balance components, and raw inventory. They are not assigned invented decimals or silently deleted. Cached metadata is reused; historical effects are reprojected when metadata becomes available.

Automatic portfolio visibility uses the same CoinGecko-listed criterion as ANKR's Advanced API whitelist. This is a listing criterion, not a safety endorsement. Native SUI is always eligible; explicitly tracked tokens remain eligible. All discovered holdings are stored, including unlisted assets.

## History semantics

The affected-address transaction index covers incoming and outgoing effects, not just transactions signed by the owner. Full selected transaction/effects JSON and the complete balance-change array are retained. Each transaction projects one net effect per owned coin type. This is wallet balance-change history, not a claim to list every internal smart-contract transfer separately.

- Fees and storage rebates are separated from the owner's transferred SUI amount.
- Sponsored gas is not charged to the sender's displayed transfer.
- Failed transactions remain marked failed.
- Negative net gas from storage rebates is retained; it is not converted into a fake outgoing payment.
- Swaps and multi-party transactions do not invent a single counterparty.
- Opaque pagination cursors prevent transactions sharing a checkpoint from being skipped.
- Separate recent and backfill cursors resume after interruptions. Pages and cursor progress commit atomically.
- Expired cursors restart with checkpoint overlap and deduplicate by transaction/asset identity.
- Provider resource-limit errors retry with a smaller history page.
- Missing token metadata preserves raw effects for later projection.

## USD quotes

Coinbase provides the native SUI quote. CoinGecko's Sui contract-to-ID directory supplies the listed-token identities; USD quotes are batched by those IDs. DEX Screener is the fallback for exact Sui base-token types, choosing the deepest returned pool with at least USD 1,000 liquidity. Move separators are percent-encoded in DEX URLs; unescaped separators were rejected by its edge firewall in live testing.

CoinGecko quote timestamps are checked for freshness. Transient 502/503/504 responses get one bounded retry. A missing or failed quote never replaces a cached real quote with zero. Tokens with no published liquid market may remain unpriced; no external API can provide a genuine market price for every token.

[CoinGecko coin identity list](https://docs.coingecko.com/reference/coins-list),
[CoinGecko price endpoint](https://docs.coingecko.com/reference/simple-price),
[DEX Screener batch endpoint](https://docs.dexscreener.com/api/reference).

## Persistence and app integration

Schema v19 adds Sui sync state, exact holdings, resumable history cursors, transaction details, and raw pages, with account-scoped indexes and reset guards. Inventory replacement is atomic. Stale runs, changed accounts, and old checkpoints cannot overwrite a newer inventory. Wallet reset removes all Sui account data and retains public metadata/prices.

The existing wallet refresh coordinator, asset detail refresh, shared portfolio valuation/sorting, selected display currency, offline asset information, and receive guidance now include Sui. Lock/reset cancellation uses the existing coordinator. The initial read integration did not include signing; the send integration below adds it.

## Verification

Actual read-only mainnet tests, not fixtures alone:

| Public test account | Holdings matched at identical checkpoint |
| --- | ---: |
| 0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34 | 147 |
| 0x42960e77d87a60d0a0599757beb320147510933c5e63a6ccfec3fdd54aa796fc | 7 |
| 0x6be20abe12a8e930fd8da5120fcb392753ef7b57b43401417aedaadeb1106ec4 | 2 |

Every discovered balance matched between ANKR and Sui's official endpoint. Recent transaction hashes matched for all three accounts, and older pages contained no duplicate hashes. These accounts were found in public transactions and a public Sui issue; they are not imported wallets and no private material was used.

Live prices were retrieved for 23 listed holdings. Native Coinbase/CoinGecko quotes agreed within the test's 5% tolerance; three contract-specific DEX/CoinGecko comparisons agreed within 10%. These tolerances accommodate changing markets and independently cached feeds; prices are not expected to match bit-for-bit.

A production synchronizer test saved 25 live receipts, native/token holdings, and prices to a fresh database, then reopened it offline and matched its portfolio. The test stopped after proving a committed page; it did not download each active account's lifetime history.

Deterministic tests cover integer precision, address balances, unknown metadata, parser validation, wrong owners/networks, partial GraphQL errors, resource-budget retries, credential-safe fallback, gas sponsorship/rebates, stale prices, account isolation, cursor boundaries, cache reopening, reset fences, and missing-metadata reprojection.

Repeat live checks using Tools/CheckSuiLive.py with --run --database. Credentials are loaded locally, output is redacted, and all activity is read-only. Host tests and a generic iOS compile were used. No simulator, device, live transfer, or visual check was performed.


## SUI and Coin<T> sending — October 14, 2026

The shared recipient/amount/review flow now submits native SUI and fungible
Coin<T> tokens. Gas price, native funding and token funding are fetched
concurrently when Continue is pressed. Fee preparation uses two unsigned
simulations: estimate a payable budget, then validate the final exact transfer.
Token quantities never pay or absorb the SUI gas fee. Native Max reserves the
gas budget; unused gas stays with the sender. Storage refunds can exceed the
charged fee and are retained separately in execution receipts.

`SuiSendPlan` builds the programmable transaction locally from validated coin
references and address-balance withdrawals. It supports merging/splitting owned
coins, native gas coins, address-balance gas, and redemption of address funds.
No remote transaction builder controls signing bytes. Amounts are UInt64 atomic
integers; Move type identities remain case sensitive. Plans expire after two
minutes for authorization, and the signed transaction has chain-bound,
randomized, finite-epoch replay protection. Funding is checkpoint-pinned,
queries use ten-object pages, and transactions have a bounded 128-object input
limit. Oversized inventories fail safely rather than silently truncating funds.

Ed25519 signs Blake2b-256 of the Sui transaction intent. A fixed public fixture
matches bytes, intent hash, address and transaction digest from Mysten SDK
`@mysten/sui` 2.36.0. Both SDK and CryptoKit signatures verify. The vault checks
wallet/account ownership and the persisted plan, performs fresh biometric/PIN
authorization, derives the selected Sui key, verifies its address, and rejects
stale authorization after locking. SUI HD keys use the existing WalletCore
account path; imported Ed25519 keys use the same address verification.

Schema v34 stores plans. Reservations cover the sender across duplicate wallet
imports. Exact signed bytes and history entries commit before submission.
Only confirmed execution effects settle success/failure. Timeouts preserve an
unknown broadcast; recovery checks its digest and may resubmit the same bytes.
Provider fallback never signs a replacement transaction. Foreground recovery
and the existing durable balance-refresh worker include Sui. Balance refresh
is complete only once a committed inventory reaches the transaction's observed
checkpoint. Failures go through OathDiagnostics and the shared outbox.

### Checks actually performed

- Generic iOS application build: passed, without installing or launching.
- Sui builder/transport host tests: 11 deterministic tests passed. Coverage
  includes SDK compatibility, exact integer limits, quote expiry, wrong
  owner/network, failed simulation/execution, mixed funds, provider fallback,
  timeout reconciliation, exact-byte retries and diagnostic redaction.
- Send journal: four tests passed for cross-wallet reservations, authentication
  cancellation, persistence across reopen, tampering, testnet rejection in the
  production ledger, unknown submission retention and failed execution.
- Production vault/imported-key authorization: nine host checks passed. PIN,
  missing biometrics, wallet ownership, signing, and locking during biometric
  authentication were exercised. OS biometrics and HD derivation were host
  substitutes; this is not an iOS authentication runtime test.
- Database Sui/post-send suite: 18 passed, two opt-in read tests skipped.
- OathDiagnostics suite: 33 passed, two opt-in tests skipped. Diagnostics
  coverage guard passed with no new exclusions.
- Real testnet transfers used the production Swift builder, signer and GraphQL
  client, dedicated faucet-funded test wallets and a test-only Move token.
  Assertions checked execution status and exact recipient/sender balances.
  No user wallet or mainnet signing/broadcast was used.
- A public mainnet account's fee preparation/simulation passed through the
  configured provider chain: 100,198 MIST net fee, 3,176,000 MIST budget,
  100 MIST reference gas price at that snapshot. This is read-only evidence,
  not a promise of future fees or mainnet transaction execution.
- No simulator, physical-device installation, visual test, or real biometric
  prompt was performed.

Representative confirmed testnet digests:

| Scenario | Transaction digest |
| --- | --- |
| SUI, including idempotent resubmission | `7KQxBWFbi7jBgV9dJycWUHDFAp42wgJATm4qXZBXRRsQ` |
| Token partial amount | `FuSRMgiMqMpbfF49SB8z21CGmEPL8cG51PG7kY6LJhr8` |
| Token Max | `H44sZg1yyFugyHapYTX3gVZLN9QG7aMZqQCf18GB3bDr` |
| Token with coin-object gas | `7qyJQVQE7wQ4bMq66anhbTUPPtLaWpCdJjTEnra8dAYq` |
| Token Max with coin-object gas | `HTXFqzaD7pXP58K2EwC14RbZTmDuwgHPU7i1eRiKXjsd` |
| Native SUI Max | `GfndnkF28QDN1BajfHbKQCghmEZXXRXCiHFTQGrJhniN` |

The test-only token type is
`0xd1096e281afa6903192e672002670f5fd791588b8e92357a22e18f4b64cff718::test_coin::TEST_COIN`.
It has six decimals and no financial value. Re-run deterministic tests with
`swift test --package-path Packages/OathAnkr --filter SuiSend`, journal tests
with `swift test --package-path Packages/OathDatabase --filter SuiSendJournal`,
and authorization checks with `python3 Tools/CheckMultiWallet.py --sui-send`.
Live tests are opt-in: `OATH_SUI_TESTNET_KEY_FILE` points to a dedicated raw
32-byte testnet-only Ed25519 key file and `OATH_SUI_TESTNET_TOKEN` names its
funded token type. Never supply an application/user wallet key. The token round
trip sends the fixture wallet's full token balance and returns it. The public
mainnet simulation requires `OATH_LIVE_SUI_KEY` but never signs or broadcasts.

Protocol references: [Sui GraphQL](https://docs.sui.io/develop/accessing-data/graphql/query-with-graphql),
[Mysten transaction SDK](https://sdk.mystenlabs.com/sui/transactions/basics),
and [BCS definitions](https://github.com/MystenLabs/ts-sdks/blob/main/packages/sui/src/bcs/bcs.ts).
