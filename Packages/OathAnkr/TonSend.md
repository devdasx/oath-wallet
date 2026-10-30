# GRAM / Jetton sending

Oath's `ton` network is displayed as **Gram / GRAM**. Sending uses the same
WalletCore V4R2 address and Ed25519 derivation for ordinary wallets, or the
pinned original TON multisig contract for GRAM multisig wallets, plus
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
an unchanged V4R2 wallet sequence read at that masterchain block. Multisig
expiry instead checks its replay dictionary at the pinned block: an accepted or
garbage-collected query remains unresolved until its receipt is found.

The durable external-message hash is available before broadcast. On confirmation,
native transfers use the initiating transaction hash; Jettons use the recipient
Jetton-wallet transaction hash used by token history. Atomic database migration
and matching history replacement prevent duplicate local transfer rows.

The implementation supports the V4R2 and original multisig wallets Oath
creates/imports, not arbitrary wallet contract versions, NFTs, extra currencies or arbitrary
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


## GRAM multisig — 2026-10-22

Creation accepts 2–7 distinct Ed25519 keys and any threshold from 1 through the
number of keys. Sources can be mixed: fresh BIP39 recovery phrases, imported
BIP39 phrases (including passphrases), and 32-byte hexadecimal private keys.
BIP39 signers use `m/44'/607'/0'`. These are BIP39 phrases, not TON-specific
24-word mnemonic encoding. All signing keys are held in the local encrypted
wallet; this is not a remote co-signer coordination service.

The immutable owner list is sorted by public key. The contract is the original
external-signature multisig distributed by `@ton/ton 16.3.0`, with pinned code
cell hash `5a55840263d27945feb55b53fa85afa4f9dd61ea573e1eeba1ecac9c96581881`.
Its source and wire implementation are documented at:
- https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/multisig-code.fc
- https://github.com/ton-org/ton/tree/v16.3.0/src/multisig

Mainnet and testnet use the same contract, message construction, quorum checks,
fee simulation and receipt verification. Network-specific wallet IDs
`0x4f415448` / `0xcf415448` produce different addresses and signed payloads to
prevent replay across networks. Only testnet funds are used by live checks.

A wallet can receive before deployment. Its first signed transfer includes the
state initialization. Each send gathers the required distinct signatures after
normal passcode/biometric authentication and journals the exact message before
broadcast. The contract uses expiring query IDs, not V4R2 sequence numbers.
Quotes are usable for 90 seconds; signed multisig orders have a 65-minute chain
expiry because the contract requires at least an hour when receiving a new
multi-signature order. Repeated broadcast uses the same query and signatures.

Recovery retains every signer, threshold, derivation convention and address in
the encrypted vault and backup (minimum formats 20 and 17 respectively). Older
readers reject these formats. Recovery export is a versioned JSON bundle;
restoration validates private material against each public key and the address.

The host checks are `TonMultisigTests`, `TonMultisigBackupTests` and
`python3 Tools/CheckMultiWallet.py --ton-multisig`. Independent reference vectors
are generated by `Tools/GenerateTonMultisigVectors.cjs`; Swift-produced messages
are executed by `Tools/CheckTonMultisigContract.cjs` in the official TVM sandbox.
The opt-in `TonMultisigLiveTests` require `OATH_GRAM_MULTISIG_LIVE` pointing to a
private, funded disposable fixture folder outside the repository. Never commit
that folder: it contains secret keys and recovery material. The test writes a
separate public-only `evidence.json` with transfer hashes and observed amounts.


### Verification completed on 2026-10-22

- Public TON testnet: ten confirmed transfers (native GRAM and standard TEP-74
  Jettons for 1-of-2, 2-of-3, 3-of-5, 7-of-7 and mixed-source 3-of-3). The mixed
  wallet requires all three sources: raw imported key, fresh BIP39 phrase, and
  BIP39 phrase with a passphrase. Sender balance changes and exact production
  history entries were checked, in addition to recipient-delivery trace proof.
- 108 SDK reference vectors cover native/Jetton messages for all 27 thresholds
  on both network configurations. Host tests also reject invalid policies,
  duplicate signers, insufficient quorum, tampered signatures/messages and
  mismatched network state; replay-state tests protect accepted/cleaned queries.
- The official TVM sandbox executed 54 native payments using Swift-produced
  messages (27 thresholds for each network configuration); 96 replay and
  insufficient-quorum checks passed. Replay rejection uses contract exit code 35.
- WalletCore 4.8.4 WASM derivation agrees with independent BIP39/SLIP-10 derivation
  for both phrase sources. This is separate from iOS runtime HD derivation.
- 28 host integration assertions cover draft preparation, limits, duplicate
  keys, passcode protection, lock/unlock, encrypted storage, authenticated
  signing, exact-byte restart recovery, and encrypted backup restore.
- Existing send/journal/ledger tests and backup tests passed. Diagnostics
  coverage and diagnostics host tests passed. The generic iOS build passed.

Public transfer evidence is in
`output/gram-multisig-20261022/confirmed-transfers.json` at the repository root.
No mainnet funds were spent. No simulator, device or physical biometrics were
used. The supported standard-token and threshold cases are tested; this is not
an assurance of zero bugs or compatibility with every nonstandard Jetton.
