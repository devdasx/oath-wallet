# Solana sending

The send flow supports SOL, classic SPL Token and standard Token-2022 transfers,
including Token-2022 transfer fees. App signing is mainnet only. Test helpers opt
in to devnet/testnet with separately generated keys outside the repository.

## Transaction preparation

`SolanaSendClient` verifies the cluster genesis, reads confirmed balances and
mint/account metadata, and builds instructions locally. Independent reads overlap
behind a four-request permit limit. Requests have a ten-second timeout and bounded
response sizes. Mainnet uses the configured ANKR endpoint and the official RPC
fallback. Provider failures go through OathDiagnostics and the shared outbox.

The quote uses exact UInt64 atomic amounts. It discovers all source token
accounts for the mint, excludes frozen balances, and spends the largest accounts
first. It creates the destination associated token account idempotently using the
correct token program. Account-creation rent appears separately in review and is
included in the total. Optional UTF-8 memos are included before transfers.

Simulation measures compute usage; the final message receives a 20% margin with
a 10,000-unit minimum. Priority price uses bounded recent samples. The final
network fee comes from `getFeeForMessage`, followed by a second simulation.
Native Max deducts the network fee. Token Max uses spendable token balances while
requiring SOL for the fee and account rent. Transfer-fee tokens show the net
recipient amount and encode the expected fee in the checked transfer instruction.

Unknown or transfer-restricting Token-2022 extensions (including transfer hooks,
confidential transfers, non-transferable tokens, interest/scaled UI amounts) are
explicitly rejected before signing. They are **not** claimed as supported. Frozen
destination accounts, changed mint decimals/programs, invalid owners, excessive
fees, stale slots and missing fee results also fail closed. Multisig token owners
and durable-nonce transactions are not part of this send implementation.

## Authorization and recovery

The selected Solana derivation address/path is used consistently for balance,
quote, reservation and signing. Imported 32-byte seeds and existing WalletCore HD
paths use the existing vault authentication. An authentication-generation check
rejects lock/reset races. CryptoKit signs the locally compiled message; the signed
wire transaction is verified against the immutable plan before journaling.

`v43_solana_send` stores the plan with a send foreign key. The active-source index
prevents competing spends across duplicate imports. The existing indexed status
queue enrolls signed records automatically. The signature and full signed payload
are persisted before broadcast. Retries replay exactly those bytes and never
refresh the blockhash or create a second authorization in the background.

Submission acceptance is distinct from finality. The worker checks the signature
and exact finalized transaction bytes and execution result. Confirmed/failed
receipts update transaction/send state, release the status job and request a
balance refresh at or beyond the settlement slot. An expired blockhash is terminal
only after finalized height, a historical transaction lookup and archive coverage
checks. Pruned/unknown history retains the journal for later reconciliation.
History synchronization preserves the intended sent amount instead of replacing
it with the wallet's net SOL debit (which also includes fees/rent).

Recovery uses the existing app-level worker and resumes after reopening. iOS
controls suspended/background execution; continuous execution while force-quit is
not promised. No new user-facing tracking screen or diagnostics table was added.

## Verification as of 2026-10-14

- Generic iOS build succeeded; no simulator or physical device was used.
- Independent official JS SDK vectors: SOL, SPL, Token-2022 and checked transfer
  fees, exact message bytes, signature verification, 128 associated addresses.
- Host RPC regressions: Max/fees, multiple sources, frozen account selection,
  owner/mint/extension validation, stale slots, failure/cancellation, exact replay,
  finality, expiry/pruned history and diagnostic redaction.
- SQLite tests: exclusive reservations, selected derivation, durable signatures,
  process reopening, terminal states, history merge and balance slot proof.
- Shared status-worker tests include Solana and a future-chain fixture.
- Nine vault authorization checks pass (real vault/PIN/imported-key signing;
  synthetic biometric store; HD derivation not executed by that host harness).
- OathDiagnostics host tests and diagnostics coverage guard pass.
- Public devnet read-only preparation passed for SOL and classic SPL, including
  destination account creation. Each quoted a 5,000-lamport network fee; SPL also
  quoted 1,488,440 lamports of account rent under the current devnet parameters.
  These checks use a documented public example account and simulate with signature
  verification disabled. They are **not** signed transaction/broadcast tests.
- Funded public-network transfers remain pending: the isolated fixture has zero
  SOL, and RPC airdrops have returned rate-limit/internal errors. The official
  faucet is available for manual funding. Do not describe public broadcast or
  final settlement as verified until the opt-in tests below actually pass.

## Repeating the checks

```sh
swift test --package-path Packages/OathAnkr --filter SolanaSend
swift test --package-path Packages/OathDatabase --filter 'SolanaSendJournalTests|SolanaLedgerTests|SendStatusTrackingTests'
python3 Tools/CheckMultiWallet.py --solana-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
```

For public read-only preparation, set `OATH_SOLANA_PUBLIC_QUOTE=1`. This checks
real RPC fee and simulation responses without signing or spending. Test availability
depends on the public example account and provider quotas.

For funded live transfers, keep an isolated mode-0600 fixture outside the repo:
`seed` and `recipientSeed` (hex 32-byte test-only seeds), matching `sender` and
`recipient`, and `network` (`devnet` or `testnet`). Fund only with free test SOL.
`Tools/PrepareSolanaTestnetFixture.cjs` creates/replenishes classic SPL, Token-2022,
and transfer-fee mints with the official SDK. It stores their public mint addresses
in that private fixture; it never performs the transfers under test.

Run the durable status test first, then the transfer/Max tests:

```sh
# SDK dependencies are installed outside the repository.
NODE_PATH=/tmp/oath-solana-reference/node_modules \
  OATH_SOLANA_TESTNET_FIXTURE=/tmp/oath-solana-testnet-fixture.json \
  node Tools/PrepareSolanaTestnetFixture.cjs
OATH_STATUS_LIVE=1 swift test --package-path Packages/OathDatabase \
  --filter SendStatusLiveTests/testLiveSolanaNativeSPLAndToken2022
OATH_SOLANA_TESTNET_FIXTURE=/tmp/oath-solana-testnet-fixture.json \
  swift test --package-path Packages/OathAnkr \
  --filter SolanaSendLiveTests/testLiveNativeSPLToken2022AndFeeToken
```

The live test uses the production Swift planner/signer/client. It checks finalized
execution, exact sender/recipient balance changes, fees, rent, token fees, Max,
multiple source accounts and duplicate replay. The database test journals a signed
transaction, reopens the database, and lets the real worker broadcast/reconcile it.

## Protocol references

- [sendTransaction](https://solana.com/docs/rpc/http/sendtransaction)
- [simulateTransaction](https://solana.com/docs/rpc/http/simulatetransaction)
- [getFeeForMessage](https://solana.com/docs/rpc/http/getfeeformessage)
- [getSignatureStatuses](https://solana.com/docs/rpc/http/getsignaturestatuses)
- [getFirstAvailableBlock](https://solana.com/docs/rpc/http/getfirstavailableblock)
- [Token-2022 extensions](https://www.solana-program.com/docs/token-2022/extensions)
- [Public example account](https://solana.com/docs/rpc/http/requestairdrop)
