# Aptos sending — implementation and verification

Verified October 14, 2026. Sending is integrated into Oath Wallet's existing
recipient, amount, review, authentication, result, history and durable status
tracking flows.

## Supported transfers

- Native APT through `0x1::aptos_account::transfer`.
- Coin tokens (including generic Coin type arguments) through
  `0x1::aptos_account::transfer_coins<T>`.
- Fungible Assets in the account's primary store through
  `0x1::primary_fungible_store::transfer_assert_minimum_deposit<Metadata>`.
  The minimum received amount equals the reviewed amount, so a custom dispatch
  hook cannot silently reduce the recipient's deposit.

The app uses its existing legacy Ed25519 accounts: mnemonic-derived accounts
and Aptos private-key imports. Rotated authentication keys, keyless/multisig
accounts, sponsored transactions, NFTs and transfers from arbitrary secondary
FA stores are outside this implementation. Portfolio discovery may include
secondary-store balances; the send quote reads the actual transferable primary
balance and fails closed if the requested amount exceeds it. Frozen/restricted
assets must pass simulation before signing.

## Preparation, authorization and network operations

`AptosSendClient` uses the configured ANKR Aptos REST endpoint first on mainnet,
with the official full node as fallback. Pruned/absent transaction lookups also
try the official archive. Every provider is checked for the expected chain ID;
credentials are never forwarded to fallback hosts. Testnet uses the official
Aptos Labs endpoint and a separate isolated account.

Account, balances, decimals and gas-price reads overlap. Quote balance/account
reads share a ledger version. A native-only zero-amount simulation measures the
initial gas requirement; this probe is never signed or submitted. The final
positive transfer is simulated again. The maximum gas allowance is padded above
simulation, bounded to 200,000 gas units and a hard ceiling of 1 APT. Review shows
that fee ceiling; the persisted committed receipt records actual gas used times
gas unit price. Max APT reserves this ceiling, while token Max sends the full
transferable token balance and reserves APT separately.

Quotes expire after 90 seconds; signed transactions have a five-minute ledger
expiration. Before signing, the client checks sequence, authentication key,
balances and the exact simulated payload again. The vault checks the selected
wallet/account, persisted quote, PIN/biometric authorization and lock generation.
BCS bytes and signing domain/hash are constructed locally; provider-supplied
transaction bytes are never signed. Authentication and spending are serialized;
independent network reads are bounded to four in flight.

Native APT and token amounts remain exact UInt64 integers. Malformed precision,
wrong-chain responses, changed payloads, signer mismatches and invalid receipts
are rejected. Public endpoint starts are paced, and transient provider failures
use bounded retry/fallback. Cancellation is preserved.

## Persistence and recovery

Database migration `v41_aptos_send` adds `aptosSendPlans`, keyed by send ID with a
cascading foreign key. The existing indexed `sends`, `sendStatusChecks` and
`sendBalanceRefreshes` infrastructure owns scheduling and recovery; no separate
polling table or error destination is introduced.

Signed bytes, the transaction hash and outgoing history intent are committed
atomically before broadcast. Ambiguous submission retains those exact bytes;
recovery never signs a replacement automatically. Node acceptance is submitted,
not confirmed. The worker resolves confirmed, execution-failed, proven-expired
or proven-replaced outcomes and releases the status job only at a final outcome.
A missing/pruned lookup alone is never treated as failure. Restarted workers
recover expired leases and resume tracking from the database.

Normal history sync preserves a local payment's recipient and stable activity ID
instead of duplicating it from withdrawal events. The committed ledger version
is retained so a balance refresh completes only after reaching that version.
Failed execution also refreshes the APT balance because gas may have been spent.

The app can resume this work when running/unlocked and uses its existing iOS
background lifecycle integration. This does not claim continuous execution while
iOS suspends or force-quits the app.

All error boundaries use shared `OathDiagnostics` / `DiagnosticHTTP`. Only a
strict transaction-by-hash 404 `transaction_not_found` is expected pending
absence. Failures are filtered before the shared outbox; no keys, credentials,
raw transactions, addresses, request parameters or response bodies are logged.

## Live testnet evidence

The user's faucet receipt was verified on testnet before spending test funds.
A test-only Move module creates an independent Coin and Fungible Asset. No
mainnet transaction was signed or broadcast during validation.

| Check | Verified testnet transaction |
| --- | --- |
| APT transfer, exact recipient/sender balance deltas and actual gas | [APT receipt](https://explorer.aptoslabs.com/txn/0x6baddc34616292cbf431a9a5e7456bbebc98e24e8fd29e81dc4b411971e2391e/overview?network=testnet) |
| Coin transfer with exact token deltas | [Coin receipt](https://explorer.aptoslabs.com/txn/0x362a007a4b1fdbcf5e14027477273b7a602fb9056a1a98232d10c1d67667bc07/overview?network=testnet) |
| FA transfer with minimum-deposit assertion and exact token deltas | [FA receipt](https://explorer.aptoslabs.com/txn/0xa8c573dd50c192051c96c120a9394cb90b8ba1103e5d8a9eeae1b5677bf9aa41/overview?network=testnet) |
| APT Max, gas reserved | [APT Max receipt](https://explorer.aptoslabs.com/txn/0x58b5fb830cee6323bfcb473f56fc46ddead85d4ccd44819def0e25c4324bbf5b/overview?network=testnet) |
| Coin Max, zero remaining token balance | [Coin Max receipt](https://explorer.aptoslabs.com/txn/0x325dfeffe2a6372aa49989e89d0fca9b2d6c0a45272a737003d9d7334481da79/overview?network=testnet) |
| FA Max, zero remaining token balance | [FA Max receipt](https://explorer.aptoslabs.com/txn/0xae877a6b9a7cc253ef3dc1b82ce02795260584d73d632816ced80ffe40becf92/overview?network=testnet) |
| Deliberate insufficient-gas execution failure: no recipient credit, gas recorded | [Failed receipt](https://explorer.aptoslabs.com/txn/0xae8746904b456959953692f63b1e650dd8a9ff69de496275ddc2d05225cdd21e/overview?network=testnet) |
| Database reopen, APT tracking resumes and job removed after confirmation | [APT restart receipt](https://explorer.aptoslabs.com/txn/0x9b194e936b616f2487ba29f7b728a86eaf85188e12eb24a3578a2aad38fabc3a/overview?network=testnet) |
| Same restart recovery for Coin | [Coin restart receipt](https://explorer.aptoslabs.com/txn/0x86b45296c9300078425d4b660859ae906f52c214b9e48c3a77aa0f39397194a3/overview?network=testnet) |
| Same restart recovery for FA | [FA restart receipt](https://explorer.aptoslabs.com/txn/0xb9d3c3dadbba5ebe7e013dc57422c156a7fd225642e475483a777a8eaabe0a24/overview?network=testnet) |

The live tests exercised the production Swift fee/crypto/network client and the
production database status worker. Restart tests insert isolated testnet records
in a test database because the production app deliberately accepts mainnet
plans only. This is database reopen/recovery evidence, not an iOS app restart test.
Exact-byte replay returned the existing committed transaction, without a second
payment. The configured ANKR mainnet endpoint separately passed read-only chain
identity and balance checks. Mainnet broadcasting remains untested.

Aptos Labs' unauthenticated testnet endpoint returned HTTP 429 during extended
runs. The live harness paces calls and uses bounded backoff; the final Max/failure
run passed after 157 seconds. This is not a performance benchmark for ANKR or an
assertion that all testnet runs avoid provider throttling.

## Automated checks completed

- Nine Aptos client/crypto host tests, including four independent official
  TypeScript SDK 7.5.0 vectors, generic Coin encoding, signature verification,
  simulation/receipt checks, provider fallback, archive lookup, cancellation,
  overflow, Max and sequence changes.
- Two existing TRON crypto tests passed after factoring the shared SHA3/Keccak
  primitive. Four unrelated live TRON tests were opt-in and skipped.
- Nineteen Aptos/database/status host tests passed; two unrelated live Aptos
  read tests were opt-in and skipped. Tests cover signed durability, duplicate
  imports, invalid receipts, failure/expiry/replacement, history hydration,
  status leases and balance-version tracking.
- Nine app vault/PIN/imported-key authorization checks passed. OS biometrics and
  HD derivation are fixtures in this host harness; they are not device evidence.
- OathDiagnostics: 39 host tests passed, two backend opt-in tests skipped.
- Diagnostics coverage passed at 349 observed catch sites.
- Generic iOS build succeeded with signing disabled.
- No simulator or physical device was launched. Visual behavior, actual Face ID
  and mnemonic HD signing on iOS were not runtime-tested.

## Reproducing

Host checks:

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-aptos-ankr-build --build-system native --filter 'AptosSendTests|TronSendTests'
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-aptos-db-build --build-system native --filter 'Aptos|SendStatusTrackingTests'
python3 Tools/CheckMultiWallet.py --aptos-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --scratch-path /tmp/oath-aptos-diagnostics-build --build-system native
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere -destination 'generic/platform=iOS' -derivedDataPath /tmp/oath-send-status-ios CODE_SIGNING_ALLOWED=NO build
```

Testnet fixture setup: install `@aptos-labs/ts-sdk@7.5.0` outside the repository,
set `OATH_APTOS_SDK_ROOT` to the directory containing its `node_modules`, then run
`node Tools/PrepareAptosTestnetFixture.mjs`. It creates a mode-0600 private fixture
in `/tmp` and prints only the public address. Fund it with test APT at the faucet.
Use Aptos CLI 9.6.0 or later and run the tool with `--publish` to deploy the
included test-only token module. `OATH_APTOS_CLI` can select the CLI executable;
`OATH_APTOS_FRAMEWORK_ROOT` can select the pinned local framework checkout.

`python3 Tools/CheckAptosSendLive.py --run` explicitly opts into isolated testnet
transfers and runs the transfer/Max/failure and restart suites sequentially.
The test wallet must not be used concurrently by other tests. Fixture secrets
must stay outside source control. The optional mainnet read test requires
`OATH_APTOS_MAINNET_RPC_PLIST` pointing to the existing private RPC configuration;
it makes only chain-identity and balance reads.

## Protocol references

- [Aptos full-node REST API](https://aptos.dev/build/apis/fullnode-rest-api)
- [Simulation](https://aptos.dev/build/sdks/ts-sdk/building-transactions/simulating-transactions)
- [Fungible Asset standard](https://aptos.dev/build/smart-contracts/fungible-asset)
- [Pinned test framework](https://github.com/aptos-labs/aptos-framework/tree/ad8f79ad0f75e38e869d2e66509b9f7511aa6c86)
