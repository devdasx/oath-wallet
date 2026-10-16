# GRAM / Jetton sending

Oath's `ton` network is displayed as **Gram / GRAM**. Sending uses the same
WalletCore V4R2 address and Ed25519 derivation as the existing wallet, plus
standard TEP-74 Jettons. No new provider credential is required: mainnet node
reads and broadcast use the configured ANKR key, with Toncenter fallback;
TonAPI supplies execution emulation and message traces. Testnet uses Toncenter
and TonAPI's explicit testnet endpoints. Genesis checks prevent mixed networks.

## Authorization and persistence

- Hash-checked trace decoding supports ordinary cells and library references,
  including Jetton deployment messages that use shared contract code.
- All amounts remain exact integers. Jettons support the complete 120-bit
  `VarUInteger 16` range; native balances/fees use UInt64 nanograms.
- Quotes bind the source key/address, recipient, amount, token master and both
  Jetton-wallet addresses, memo, sequence, expiry and exact wallet code.
- The master getter derives each Jetton wallet; the source wallet getter must
  agree on its owner/master. Indexed decimals must match the selected asset.
- Native Max reserves the simulated fee plus a buffer. Jetton Max transfers
  the whole token balance, while keeping native GRAM for execution. Standard
  Jetton sends attach 0.15 GRAM; the standard contract returns unused gas.
- Fee simulation includes the complete message trace, storage/execution costs
  and forwarding fees. The quote is checked again before authorization.
- Production queue APIs accept mainnet only. The database reserves the sender
  across duplicate imports before authentication. Passcode/biometric authorization
  signs only the queued, unchanged plan; signing never runs in a view body.
- Exact signed bytes are journaled before broadcast. Retrying replays those same
  bytes and sequence; it never silently signs a replacement transaction.
- Schema v42 adds `tonSendPlans` with unique indexed message/transaction hashes.
  Existing durable status jobs resume after reopening and stop on a terminal
  result. iOS controls execution while suspended; jobs remain saved between runs.

## Confirmations and failure boundaries

Provider acceptance is submission, not recipient delivery. Confirmation verifies
the hash-checked raw transaction/message graph, expected recipient/value/body,
and successful Jetton internal transfer. A partial trace stays pending; bounces
or unsuccessful completed delivery fail. A missing index response alone never
proves failure or replacement. Expiry requires an advanced chain timestamp and
an unchanged wallet sequence read at that masterchain block.

The durable external-message hash is available before broadcast. On confirmation,
native transfers use the initiating transaction hash; Jettons use the recipient
Jetton-wallet transaction hash used by token history. Atomic database migration
and matching history replacement prevent duplicate local transfer rows.

The implementation deliberately supports the V4R2 wallets Oath creates/imports,
not arbitrary wallet contract versions, NFTs, extra currencies or arbitrary
contract calls. Frozen/unsupported wallets, nonstandard Jetton behavior and failed
simulations stop before signing. Memos are limited to 120 UTF-8 bytes. These are
capability/validation limits, not assurances that every third-party token works.

HTTP/RPC/retry/signing/storage failures flow through OathDiagnostics and the shared
outbox. Only safe chain/stage/provider-code context is recorded. No credential,
address, name, memo, key, raw transaction, or request/response body is logged.
Expected cancellation, alternative JSON forms and an exact TonAPI trace-not-found
404 are excluded; authentication and other 404 errors remain failures.

## Verification — 2026-10-14

Real free-testnet transactions ran through the production Swift fee, signing,
broadcast and receipt code, using isolated disposable keys outside the repository:

| Test | Confirmed testnet transaction |
| --- | --- |
| 0.01 GRAM | [19b605e5…](https://testnet.tonviewer.com/transaction/19b605e5ad68009fd18fe1e3751a81fc654f42559dfc40d81c651578e53f9482) |
| 0.01 OTEST Jetton | [c0f14209…](https://testnet.tonviewer.com/transaction/c0f14209d5f7cdb4670cb1f55deee95f6194271e91818bac22b144c41e31bdc6) |
| Native memo | [30ad2d52…](https://testnet.tonviewer.com/transaction/30ad2d5254db9edf2c750da1c19d3795bbdc35d4c43d0f781281a34f714f1eda) |
| Jetton Max + first wallet deployment + memo | [14648303…](https://testnet.tonviewer.com/transaction/146483031c71f423af1fda9a22d25988baf89f92608060ce71f894823dd26cef) |
| Native Max + memo | [a2306e3b…](https://testnet.tonviewer.com/transaction/a2306e3b17fa1b6d367baa5d894e9c1e8dd2012b5b54268ffae1312968a4cc35) |

The native 0.01 GRAM quote and actual trace fee both measured 487,672 nanograms.
The 0.01 OTEST quote and actual trace fee both measured 2,738,033 nanograms.
These are testnet observations, not guaranteed mainnet fees.

Separate live database tests journal both native and Jetton signatures, abandon
the worker lease, reopen the SQLite database, broadcast/reconcile through the
production worker, reopen again and verify confirmed state plus removal of the
tracking job. Production queue/signature authorization is separately host-tested
because it intentionally rejects testnet plans.

Host checks cover independent SDK signing vectors, large token quantities, BOC
validation, wrong keys/networks, stale/altered plans, library-cell hashing, cancellation, pinned expiry,
incomplete/failed delivery, forged signatures, duplicate imports, transaction-hash
migration, and history arriving before/after settlement. Authorization tests use
the real vault, PIN and imported-key signer with a synthetic biometric store.

No mainnet funds were sent. No simulator/device was launched. The generic iOS
build verifies integration; UI, physical biometrics and on-device HD derivation
were not exercised at runtime.

## Repeating the checks

```sh
swift test --package-path Packages/OathAnkr --build-system native --filter TonSendTests
swift test --package-path Packages/OathDatabase --build-system native --filter TonSendJournalTests
python3 Tools/CheckMultiWallet.py --ton-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --build-system native
```

Live tests require explicit `OATH_TON_LIVE=1` and `OATH_TON_FIXTURE` pointing to a
mode-0600 JSON file containing `seed`, `recipientSeed` (32-byte Ed25519 hex seeds),
their V4R2 raw addresses `sender`/`recipient`, and a TEP-74 `jetton` master address
with 9 decimals. Use **testnet-only** keys. Fund sender with faucet GRAM and mint
test Jettons to it. The current suite uses `/tmp/oath-gram-live` for recovery
journals/evidence; create that directory with mode 0700. The Max test funds the
recipient for gas and returns its test balances. The standard reference Jetton
contracts used here are from `ton-blockchain/token-contract`.

```sh
OATH_TON_LIVE=1 OATH_TON_FIXTURE=/path/to/isolated-testnet.json \
  swift test --package-path Packages/OathAnkr --build-system native --filter TonSendLiveTests
# The shared restart harness reads /tmp/oath-ton-testnet-fixture.json:
OATH_STATUS_LIVE=1 swift test --package-path Packages/OathDatabase \
  --build-system native --filter SendStatusLiveTests/testLiveTonNativeAndJetton
```

`Tools/GenerateTonSendVectors.cjs` regenerates public fixed-key reference vectors
with `@ton/ton 16.3.0`, `@ton/core 0.63.1` and `@ton/crypto`. The app does not ship
these JavaScript dependencies. Pinned V4R2 bytecode attribution is included in
ThirdPartyNotices.txt.

## Primary references

- [Wallet V4](https://docs.ton.org/standard/wallets/v4)
- [TEP-74 Jettons](https://github.com/ton-blockchain/TEPs/blob/master/text/0074-jettons-standard.md)
- [Messages and transactions](https://docs.ton.org/foundations/messages/overview)
- [TonAPI emulation](https://docs.tonapi.io/tonapi/rest-api/emulation)
- [TonAPI schema](https://github.com/tonkeeper/opentonapi/blob/master/api/openapi.yml)
- [Acton testnet faucet](https://ton-blockchain.github.io/acton/docs/wallets#fund-a-wallet-on-testnet)
