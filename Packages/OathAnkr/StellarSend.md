# Stellar sending — October 14, 2026

Oath Wallet now routes Stellar through its existing Recipient → Amount → Review →
authentication → result flow. The app uses mainnet; public Testnet tests run on
macOS with separate faucet accounts. No production wallet key, simulator, or
physical device was used for verification.

## Implemented

- XLM payments and account activation (`CreateAccount` when the recipient is new).
- Classic issued assets with exact code/issuer identities, both 4- and 12-byte
  asset-code encodings, 7-decimal amounts, authorization, trust-line capacity,
  buying/selling liabilities, and issuer redemption.
- Standard SEP-41 contract tokens: balance/decimals checks, transfer simulation,
  exact i128 quantities, reviewed resource/inclusion fee limits, and source-account
  authorization. The signer constructs the transfer operation locally and only
  accepts the exact matching source authorization tree.
- Text, ID (including zero and UInt64.max), hash and return-hash memos for classic
  transfers. Required-memo recipients are checked before signing. Soroban does
  not permit transaction memos; those combinations receive a specific error,
  rather than silently dropping the memo.
- Max protects the XLM reserve, sponsorship adjustments, liabilities and fees.
  Token Max sends the available token balance while reserving gas in XLM.
- Production vault authentication, imported-key / existing HD-key adapters,
  durable signed-envelope storage, same-byte retries and background reconciliation.
  Duplicate wallet imports sharing a sender cannot reserve overlapping sequences.
- Pending responses stay pending. Only an exact confirmed Horizon envelope or
  typed absence across the complete retained validity interval settles a send.
  Failed execution never becomes transfer success. Actual charged fees replace
  the reviewed cap after settlement, and balance refresh uses the shared worker.
- Shared OathDiagnostics boundaries and task-local correlation; no request
  parameters, envelopes, keys, account fields, or raw provider responses in logs.

The implementation uses ANKR Horizon and Soroban first, with public Horizon and
Gateway.fm RPC fallback. Network identity is verified before use. Mainnet ANKR
Horizon identity, ANKR `getNetwork`/`getFeeStats`, and fallback fee calls were
checked read-only. No mainnet payment was broadcast.

A live test exposed that Horizon's `max_fee` sample includes contract resource
fees. Those are not an appropriate inclusion-fee estimate for ordinary payments.
The implementation uses RPC's separate inclusion-fee distributions, then adds
simulated resource fees only for a contract transfer.

## Confirmed public Testnet evidence

These transactions were built, signed and submitted by the production Swift
Stellar sender. Tests checked recipient balance deltas, actual fees and retry
idempotence, rather than treating a submission response as confirmation.

| Case | Transaction hash | Observed outcome |
| --- | --- | --- |
| XLM | `cb0096008b9cbe08ef299f99a67a1ef2873c0b4de4e40a22f2aea08c19bb03c3` | Exact 0.1234567 XLM delivery; 100 stroops charged; retry did not pay twice |
| Classic token | `5a4e9461ae90e2147aeb6c14b2b61ab8d730ea3ff3740f70085253d79e7273ff` | Exact 0.1234567 OATHLONG delivery; 100 stroops charged; idempotent retry |
| Account activation | `89d2ffe272a62e993b5d06f754181104f7239bc358ad69730dd73eb13b2dd1c7` | New account received exactly 3 XLM |
| XLM Max | `a6cd754d7c15cbc7ac5ef0e917e16b6c68e0d16133c4b3afcb6acdea54e0ee5d` | Exact delivery; reserve remained; 100 stroops charged |
| SEP-41 token | `b61b0c6018822aef27a32a0e4bdd111e3bc52f00e4a89720d343938fc222babb` | Exact 1.234567 OAT delivery; 451,037 stroops charged, below 526,524 cap |
| SEP-41 Max | `29fb24cdb8c081631b084cc6c3481f7a58641a47da04bade538551b62f019c58` | Remaining tokens delivered; source token balance zero; 12,100 stroops charged |
| Failed activation race | `04e1d9c62eb7607bc2f84cc29d6fa5671b6bd9704a87f5bdd95b3b1cb241c439` | Confirmed failure; 100 stroops charged; no extra delivery; never reported success |

Look up a hash at `https://horizon-testnet.stellar.org/transactions/<hash>`.
Public Testnet history is subject to resets and retention.

The custom 6-decimal token was compiled from the official
[`stellar/soroban-examples` v23.0.0 token contract](https://github.com/stellar/soroban-examples/tree/v23.0.0/token),
then uploaded, deployed, and minted on Testnet. It is a real contract-only token,
not a classic-asset wrapper or a mocked simulation.

## Repeatable checks

```sh
swift test --package-path Packages/OathAnkr --scratch-path /tmp/oath-stellar-host --filter Stellar
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-stellar-db --filter StellarSendJournalTests
python3 Tools/CheckMultiWallet.py --stellar-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --scratch-path /tmp/oath-stellar-diagnostics
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/oath-stellar-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Results: 40 Stellar-selected package tests, 6 opt-in checks skipped in the offline
run, zero failures; the four new live Testnet test methods were run separately
and passed. Five durable-journal tests and nine production-vault authorization
host checks passed. Diagnostics: 36 tests, 2 opt-in skips, zero failures. Coverage
passed and the generic iOS build succeeded.

SDK reference vectors use `@stellar/stellar-sdk` 17.2.1 outside the app. They
verify complete unsigned envelope bytes and transaction hashes for native,
classic short/long code, activation, contract, and all memo encodings, plus
independent SDK signatures. CryptoKit can randomize Ed25519 nonces, so signature
byte equality is not assumed. No SDK or new cryptographic dependency was added
to the app.

`Tools/PrepareStellarTestnetFixture.cjs /tmp/<fresh-fixture>.json <token.wasm>`
creates private mode-0600 Testnet fixtures, using an external installation of the
pinned SDK through `NODE_PATH`. Then set `OATH_STELLAR_TESTNET_FIXTURE` to that path
and run `StellarSendTests.testLive`. Use a fresh fixture for another full run:
contract Max intentionally empties the source token balance. Never use real
wallet credentials or commit the fixture. Only the deterministic, unfunded SDK
vector keys are public in the repository.

The authorization harness exercises the actual vault, PIN gates, journal and
imported-key signer. Its biometric store is synthetic; the WalletCore HD adapter
is compiled for iOS but is not run on the host. Simulator/device UI, physical
biometrics and mainnet transfers remain untested.

All 16 new Stellar strings are supplied in English and Arabic. A targeted bundle
check covers all 57 language choices. The existing broad localization checker
stops on its unrelated assumption that Chinese `walletTab` must still equal
English; that pre-existing translation was preserved.

## Deliberate boundaries

This release accepts ordinary G-address recipients. Muxed M-addresses, multisig /
external signing authorities, arbitrary contract calls, and contract authorization
trees requiring additional signers are rejected. It does not change trust lines,
issuer permissions, or perform swaps automatically. Protocol automatic archival
restoration is encoded when supplied in transaction resources; a separate legacy
`restorePreamble` requires restoration first and is not silently authorized.

## Protocol references

- [Stellar transaction fees and reserves](https://developers.stellar.org/docs/learn/fundamentals/fees-resource-limits-metering)
- [RPC inclusion-fee statistics](https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/getFeeStats)
- [Contract transaction restrictions](https://developers.stellar.org/docs/learn/fundamentals/contract-development/contract-interactions/stellar-transaction)
- [Transaction simulation](https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/simulateTransaction)
- [Stellar XDR schemas](https://github.com/stellar/stellar-xdr)
