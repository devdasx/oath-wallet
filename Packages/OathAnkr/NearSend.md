# NEAR sending — October 14, 2026

NEAR and standard NEP-141 fungible tokens use Oath Wallet's existing Recipient →
Amount → Review → vault authorization → result flow. Production is mainnet only.
Testnet validation used separate, randomly generated, faucet-funded accounts;
no production wallet key or mainnet funds were used.

## Implementation

- Locally constructed Borsh transfers and Ed25519/SHA-256 signatures. Providers
  never supply transaction bytes for the wallet to sign. Exact unsigned bytes
  and transaction hashes match near-api-js 7.3.1; signatures cross-verify with it.
- Named and implicit recipients; native transfers can activate an absent implicit
  account. Named recipients must already exist. Only the selected account's
  Ed25519 FullAccess key can authorize these sends.
- Exact u128 decimal-string amounts, including 24-decimal NEAR and six-decimal
  tokens. Fresh balances and on-chain token decimals are checked. Staked NEAR
  and account storage reserves cannot be spent. Max reserves the native fee;
  token Max preserves NEAR for gas and registration.
- Protocol fee calculation includes action costs, argument bytes, the current gas
  price, minimum gas purchase price, and new-account charges. A 2× gas-price
  allowance is used, with 50 Tgas for ft_transfer and 30 Tgas for registration.
  The review explicitly calls this a **maximum estimate**, not the eventual fee.
  Unused gas is refunded; actual finalized receipt fees replace estimates in
  history. This reserve can require more liquid NEAR than the final burned fee.
- Missing NEP-145 registration is included as storage_deposit followed by
  ft_transfer with exactly one yoctoNEAR. Registration cost appears separately
  and in the total. Tokens without NEP-145 are allowed only after the precise
  missing-method response; contract panics are never treated as missing metadata.
- Independent reads run concurrently against a finalized block. Preflight repeats
  balance/key/metadata/storage/protocol checks before authentication. Increased
  costs or a changed intent require a new review, rather than silently re-signing.
- ANKR mainnet primary, official NEAR fallback; FastNear/official testnet endpoints
  for tests. Network validation uses protocol configuration because ANKR disables
  status. Transport/provider failures use bounded fallback; wrong-chain replies
  never do. No JSON-RPC array batching is assumed.
- Exact signed bytes are journaled before broadcast. Duplicate wallet imports
  reserve the same sender. Retry/recovery never changes nonce, recipient, amount,
  or block hash. A timeout remains pending. Expiry releases a reservation only
  after a finalized height exceeds validity and the access-key nonce proves the
  transaction was never used. Ambiguous outcomes stay reserved.
- FINAL execution, matching transaction identity, complete receipt graph and
  matching terminal execution status are required. Inclusion alone cannot show
  success. The sheet observes the durable journal while the app service handles
  recovery; confirmed failures retain their real charged fee.
- Shared OathDiagnostics/outbox, chain and operation correlation. Credentials,
  keys, raw transactions, addresses and contract-authored panic text are excluded.
  Exact optional-interface/unknown-transaction responses are documented control
  flow; provider outages and execution failures remain diagnostic.

NFTs, staking, arbitrary contract calls, restricted function-call keys, external
multisig signers, and nonconforming token contracts are outside this transfer
feature. Actual token-delivery behavior was verified for wrap.testnet; the tests
cannot certify every independently deployed contract.

## Live evidence

The production Swift sender performed the following testnet cases. The main suite
checked final receipts, exact balance changes, actual fees below their allowance,
and identical-byte retries. The intentionally rejected transfer did not deliver
any tokens. All eight main-suite receipts were independently re-read and checked
with near-api-js. Public captures are in Tests/OathAnkrTests/Fixtures/NearSend/
executions.json and are tested by the current receipt verifier.

| Case | Transaction hash | Outcome | Actual fee (yoctoNEAR) |
| --- | --- | --- | ---: |
| Activate implicit recipient 1 | `3LFVbeG2QEaegTD1ZHAfyDGgNruhjmAcksbCyA7cFunH` | confirmed | 7114989537500000000000 |
| Activate implicit recipient 2 | `DTBricbZA43rBhgEDJ1aKWXnjshuUWeUJV58KaE6xMyG` | confirmed | 7114989537500000000000 |
| Activate implicit recipient 3 | `GQuj4PPptf2iv8THEeAznFgT9uKhaijA6BqD5MwNfBfu` | confirmed | 7114989537500000000000 |
| Token + recipient registration | `74MRDwWx6jM9PmCoLcWSw6MovnT3Hgax64XSUcsWwMKK` | confirmed | 375511296416200000000 |
| Token, already registered | `CmmQ3JM2WhEFviLZarkRbKu6sTQTBpjG3MyCXSW3Hv4K` | confirmed | 216449904229600000000 |
| Rejected token send; no delivery | `7cPak8vEQh2roWTLJ8Vpq5bANXKiZFMWQULpqrf2BA1b` | failed | 185022235531400000000 |
| Token Max | `FUSYZJBDX9RqbvvhHicJVJgjcvfFTzW4hPZm5aJ2JL5m` | confirmed | 216878491100200000000 |
| Native Max | `532rvDN9tnN9oKVJQpPbx9awG1snWJYJYVyiyVQ2hiJg` | confirmed | 44636512500000000000 |
| Final preflight + native | `9uMwRzeprf1QT7Wefpzok15NC6kWbwJk6Xnvpakjp5CG` | confirmed | 44636512500000000000 |
| Final preflight + wrap.testnet | `2VxncAC1M5aAHw86Xsco89TPdRvEydYRWGQrtUHfJSUW` | confirmed | 216151017154300000000 |

The two final cases also ran the latest complete preflight and receipt verifier
against the live chain. Testnet funding/setup transactions are not counted above.
Earlier exploratory runs exposed the protocol gas-purchase-floor/account-creation
fee difference; corrected runs passed. The test-only transport paces public RPC
requests and retries 429 responses with identical request bytes.

The app's ANKR mainnet endpoint passed read-only native quoting/preflight,
new-implicit-recipient quoting, and USDT metadata/balance/storage queries.
Mainnet send_tx and broadcast_tx_commit rejected deliberately undecodable test
bytes with a parse error, establishing method availability only. No valid signed
mainnet transaction was submitted; real broadcast proof is testnet only.

## Repeatable checks

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-near-host --filter 'NearSend|NearTests'
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-near-db --filter 'NearSendJournalTests|NearLedgerTests'
python3 Tools/CheckMultiWallet.py --near-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --scratch-path /tmp/oath-near-diagnostics
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/oath-near-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Live tests are opt-in. OATH_NEAR_TESTNET_FIXTURE points to a local 0600 JSON file
containing a funded testnet sender/seed, wrap.testnet holding and three fresh
recipient address/seed pairs. Never use mainnet credentials. The main suite uses
fresh implicit recipients and consumes the remaining wrapped-token balance in
its Max test. OATH_NEAR_FINAL_TESTNET_FIXTURE reuses those recipients for reverse
transfers. OATH_NEAR_MAINNET_RPC_PLIST points to the ignored local RPC configuration
for the transport-enforced read-only primary-provider test. Do not commit any
of these private files or environment values.

Tools/GenerateNearSendVectors.mjs regenerates public SDK vectors, with
OATH_NEAR_SDK_ROOT pointing to an external near-api-js 7.3.1 installation.
The fixture's deterministic key is public test data and must never be funded.

Verified layers: targeted host/API/crypto/receipt tests, durable journal tests,
9 actual-vault/PIN/imported-key authorization checks, diagnostics tests and
coverage, generic iOS compilation, live testnet execution, and read-only mainnet
provider checks. The vault harness uses synthetic biometrics; WalletCore HD code
was compiled but not exercised on a device. Simulator, physical-device UI,
physical biometrics and valid mainnet broadcasts were not tested.

Protocol references:
[transactions and finality](https://docs.near.org/api/rpc/transactions),
[protocol configuration](https://docs.near.org/api/rpc/protocol),
[fungible-token standard](https://docs.near.org/primitives/ft/standard),
[runtime fee rules](https://github.com/near/nearcore/blob/master/docs/RuntimeSpec/Fees/Fees.md),
[near-api-js](https://github.com/near/near-api-js).
