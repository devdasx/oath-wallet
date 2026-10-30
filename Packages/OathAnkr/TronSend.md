# TRON sending — October 14, 2026

TRON now uses Oath Wallet's Recipient → Amount → Review → authentication →
result flow. The app is configured for mainnet. Live verification used separately
generated, faucet-funded Nile accounts; no production wallet credentials were used.

## Implementation

- TRX, numeric-ID TRC-10 tokens and standard TRC-20 contract transfers. Amounts
  remain exact integer SUN/atomic units, including full uint256 token quantities.
- Independent account, recipient, resource, parameter and block requests overlap.
  Token decimals and balances are checked on-chain; contract transfers are
  simulated and require the exact matching Transfer event before signing.
- Current energy/bandwidth prices, staked/delegated resources, free bandwidth,
  recipient activation and dynamic simulated energy enter the quote. Contract
  execution has 30% plus 1,000 Energy headroom and a bounded fee_limit. That limit
  covers total caller Energy, including staked Energy; the displayed allowance
  reserves the expected maximum TRX burn after current resources. Fees and
  resource availability can change before inclusion; actual fees replace the
  estimate after settlement. Contract-deployer subsidies are not assumed.
- Max uses fresh balances. TRX Max leaves the quoted fee allowance; token Max
  sends all available tokens while checking TRX/resources for fees.
- Locally constructed protobuf bytes, SHA-256 transaction identifiers and
  recoverable secp256k1 signatures. The signer never accepts a provider-built
  transaction. Complete bytes and signatures match independent TronWeb vectors.
- Vault/PIN/biometric authorization, exact wallet/account/key binding, imported
  private keys and the existing WalletCore HD adapter. The signed transaction is
  durably journaled before broadcast. Duplicate imports sharing a sender cannot
  reserve overlapping sends. No private key is retained by the submission worker.
- ANKR native HTTP primary, TronGrid fallback, exact genesis identity checks and
  bounded timeouts/responses. Retries always use identical signed bytes. A head
  node's acceptance/presence shows the shared "Transfer submitted" receipt while
  execution stays pending until solid confirmation. Already-seen
  transactions are polled without repeated broadcast. Confirmed failure records
  the fee but never claims token delivery.
- Submission monitoring continues independently of sheet dismissal, with bounded
  workers and unlock recovery. The open sheet observes the finality-checked send
  journal and updates automatically. Expiry releases a reservation only after
  exact absence across a continuous solid-block validity window; local clock
  expiration and empty lookups alone are insufficient.
- Shared OathDiagnostics/outbox and operation correlation. Provider errors expose
  only safe codes, never addresses, keys, request bodies, signed bytes or raw
  responses. Cancellation, optional missing resources, duplicate acknowledgements
  during exact-byte recovery and still-pending receipts are expected control flow.

A live test found two real response traps: an unrelated governance setting can
be `-1`, so only relevant fee parameters are parsed as unsigned; and `visible`
contract simulation responses encode log addresses differently. Contract calls
now use canonical hex mode. A zero return word is permitted only for the pinned
mainnet/Nile USDT deployments with an exact Transfer event. Other false-returning,
reverting, fee-on-transfer or nonstandard contracts that cannot prove the exact
reviewed delivery are rejected.

Multisig/changed owner permissions, TRC-721 NFTs, staking actions, arbitrary
contract calls and delegated external signers are outside this send feature.
The app never silently substitutes another signer or transaction operation.

## Submitted-screen correction — October 14, 2026

The sender previously discarded a successful `broadcasthex` acknowledgement and
returned the immediately following solidity lookup instead. Solidity had not yet
caught up, so an accepted transfer became `unknown` and the UI showed "Checking
your transfer". Exact transaction presence on the head node had the same bug.

The client now returns a distinct `submitted` outcome immediately after positive
acknowledgement or an exact signed-byte match on the head node. The app maps it to
the same submitted receipt, animated checkmark and success feedback as Bitcoin.
No post-broadcast solidity request delays that response. Timeouts, mismatched
transactions and unverified duplicate responses still do not claim acceptance.

Schema migration v39 stores acknowledgement independently of final execution.
It survives reopening and later empty lookups, while preserving signed bytes and
sender reservations. The service continues bounded confirmation work after sheet
dismissal; an open sheet also observes later failures. Only solid execution or
proven expiry settles the journal. Existing ambiguous sends are not automatically
marked accepted by the migration. Shared diagnostics and provider privacy handling
remain in place.

Verification for this correction: the new acknowledgement regressions failed
before the client fix and passed afterward. 15 TRON send/crypto host tests passed
(4 opt-in live tests skipped), plus 9 journal/migration tests and 37 diagnostics
tests (2 opt-in tests skipped). The diagnostics coverage guard and generic iOS
build passed. Tests cover TRX, TRC-10, TRC-20, delayed finality, exact-byte retry,
wrong-hash rejection, durable acknowledgement, migration, reservations and later
execution failure. No new live transfer, simulator or physical-device check was
performed for this correction. The Nile records below are earlier verification.

## Public Nile evidence

The production Swift client built, signed, broadcast and verified these transfers.
Each successful test checked exact recipient balance increase, sender TRX debit
including the charged fee, solid receipt contents, and idempotent retry.

| Case | Transaction hash | Actual fee (SUN) |
| --- | --- | ---: |
| TRX + recipient activation, 1.234567 TRX | `fb09b3315e8d7ebfa5b9558c5106ba159c694dcea1fb0c1b2a79f33f1584557f` | 1100000 |
| TRC-10 TRN, 1.234567 tokens | `a294ce5ae8f8a5090431ee9636a0b7811914bb1b1150addf9d4af74929721284` | 0 |
| Nile USDT, 1.234567 tokens | `8af5ef7899e9d8d75f2c35cb1c9c42fea180baaf921e7c287fd6ff01fff8d6dd` | 345000 |
| Standard TRC-20 OAT, 1.234567 tokens | `63bcf905bca53e6c6862941fe65aa8347d50316d1e7ae5d057b5b6550e81274b` | 3143500 |
| Deliberately insufficient Energy: failed, no token delivery | `07f108432a94253034d22d0e983a8e594e221bb9581942e1a981605f048f1075` | 353000 |
| TRC-20 Max, remaining 998.765433 OAT | `dee7ff3b6d3d6f43e1c68400ecc67af10686b5db730c330043c3db43a45c0624` | 1642500 |
| TRC-10 Max, remaining 98.765433 TRN | `d8371df8ca241d188e54eb559b46ba970608bcdc5459132eaa5987f1cf841b18` | 0 |
| TRX Max, 1.234567 TRX | `0f655bb24a17d577536c0ef430e1b241de68cb7e694b9dd109cee638d8cb448f` | 0 |

Explore at `https://nile.tronscan.org/#/transaction/<hash>`. Nile may reset history.
The OAT contract is `TPGmG2WWKGHqMKEUHk9Pwb68LwrB9ATPew`, deployed for these tests
by TronWeb; its actual transfers use the production Swift sender. Deployment:
`303081c4f8dbb451ea168ac0a46078e8767e41763f00f8a9bbb690ec870d8936`.

A separate live expiry test verified absence across the complete solid-block
window with a transport that rejects any broadcast attempt. ANKR mainnet's
production native quote path passed a read-only check in 0.642 seconds in one
sample; this is not a latency guarantee or mainnet-send evidence.

## Repeatable validation

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-tron-host --filter 'TronSend|XrplSend|TronTests'
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-tron-db --filter TronSendJournalTests
python3 Tools/CheckMultiWallet.py --tron-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --scratch-path /tmp/oath-tron-diagnostics
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/oath-tron-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Verified: 38 selected API/crypto tests (9 opt-in skips), 6 journal tests, 9 vault
host checks, and 36 diagnostics tests (2 opt-in skips), all with zero failures.
The coverage guard and generic iOS build passed. Live test methods were run
separately and passed as recorded above.

For new live fixtures, install `tronweb@6.2.2` and `solc@0.8.23` outside the repo
and point `NODE_PATH` there. Set `OATH_TRON_TESTNET_FIXTURE` to a NEW private
mode-0600 file path and run `Tools/PrepareTronTestnetFixture.cjs`. Fund its printed
public address with test TRX, USDT and TRN at the Nile faucet. Run
`TronSendTests/testLiveNileTransfers`, then deploy the test contract with
`Tools/PrepareTronTestnetContract.cjs` and run
`TronSendTests/testLiveNileTokenMaximumAndExecutionFailure` with
`OATH_TRON_EXTENDED_TESTS=1`. Finally run
`TronSendTests/testLiveNileExpiryProofDoesNotBroadcast`. Run live tests serially;
Max intentionally empties token balances, so use a fresh fixture for a full rerun.
Never use real wallet keys or commit a funded fixture. The checked-in vector
keys are deterministic, public and unfunded. Read-only ANKR verification is
opt-in via `OATH_TRON_PRIMARY_KEY`, loaded without printing it.

The authorization harness uses the real vault/PIN/imported-key path and a
synthetic biometric store. WalletCore HD derivation was compiled for iOS but
not executed in host tests. Simulator/device UI, physical biometrics and mainnet
broadcasts were not tested. iOS suspension can pause monitoring; unlock resumes
journal recovery. No claim of uninterrupted background execution is implied.

## Protocol references

- [TRON resource model](https://developers.tron.network/docs/resource-model)
- [Fee limit and Energy accounting](https://developers.tron.network/docs/set-feelimit)
- [Solid-block range queries](https://developers.tron.network/reference/getblockbylimitnext-1)
- [Nile test tokens](https://developers.tron.network/docs/getting-testnet-tokens-on-tron)
