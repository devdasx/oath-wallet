# Solana WalletConnect

Implemented October 16, 2026. The previous WalletConnect handler supported EVM
and THORChain but did not negotiate or handle Solana requests. Address matching
also assumed EVM-style case-insensitivity; Solana now uses exact base58 identity.

## Supported requests and clusters

- `solana_getAccounts`, `solana_requestAccounts`
- `solana_signMessage` for readable UTF-8 challenges
- `solana_signTransaction` for legacy and version 0 transactions
- `solana_signAllTransactions`, preserving order and existing cosigner signatures
- `solana_signAndSendTransaction`, with preflight and durable submission recovery

| Cluster | WalletConnect CAIP-2 ID |
| --- | --- |
| Mainnet | `solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp` |
| Devnet | `solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1` |
| Testnet | `solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z` |

The dApp must request, and the user must approve, each cluster. Every request
retains its explicit cluster; there is no mainnet fallback or shared mutable
RPC cluster. The provider's full genesis hash and the transaction's recent
blockhash are checked on that cluster. Reown's Solana provider switches its
default chain locally and attaches that chain to subsequent requests.

## Approval and persistence

The approval screen shows the exact network, account, fee payer, fee, simulated
SOL/SPL/Token-2022 balance changes, mint identities and invoked programs. It
distinguishes signing from broadcasting. SPL and Token-2022 delegate permissions
are reviewed separately from balances: each affected token account shows its
mint, previous delegate/allowance, requested approvals, and simulated resulting
delegate/allowance. Maximum `UInt64` approvals are marked as unlimited, with a
warning that the delegate can transfer or burn tokens without another approval.
Direct `Approve` and `ApproveChecked` requests remain visible even when they
repeat an existing allowance or a subsequent instruction revokes it. Simulated
permission changes made through another program (CPI) are also included.

Simulation is an estimate, not a guarantee of execution. Unknown metadata
remains a mint address; missing decimals display raw units rather than an
invented token amount.
Testnet metadata never uses a same-address mainnet token label.

The reviewed wire message, blockhash, fee instructions, lookup tables and other
signers' signatures are preserved. Fresh authentication and the selected Solana
derivation are checked at signing. Changed simulation results require renewed
confirmation, including changes to a delegate or allowance with unchanged
balances and fees. Version 0 address lookup tables are resolved on the selected
cluster. Broadcasts require all necessary signatures and cannot skip preflight.

Before broadcasting, the exact signed bytes and signature are committed to
`walletConnectSolanaSubmissions`, with wallet/account ownership, cluster,
fingerprint, reset guards and deletion cascades. Retries replay those bytes and
never sign a replacement. The bounded worker survives sheet dismissal and
resumes on unlock after suspension/relaunch. It updates visible results and
plays success feedback on confirmation. iOS suspension still stops execution;
this is not an always-running background service. Test-cluster submissions do
not enter the mainnet transaction history or mainnet balance refresh path.

## Original implementation verification (16 October 2026)

Host checks cover wire parsing, signatures against independently generated JS
vectors, legacy/v0/lookup transactions, cosigners, batches, malformed input,
case-sensitive ownership, cluster/genesis/blockhash rejection, simulation
changes/failures, sponsored account handling, preflight, and receipt outcomes.
Database checks cover reopening, idempotency, cluster isolation, ownership,
terminal states, reset guards and deletion. Vault checks exercise the production
PIN/imported-key signing boundary for all three clusters. Namespace checks run
the production policy against both Swift and JavaScript WalletConnect validators.

Live evidence:

- `output/walletconnect-solana-live.json`: eight checks, including confirmed
  devnet SOL, SPL and Token-2022 transfers, real on-chain lookup-table usage,
  independently verified signatures and exact recipient balance changes.
- `output/walletconnect-solana-relay.json`: isolated WalletConnect JS peers,
  all six methods, devnet/testnet request switching, production Swift signer/RPC,
  confirmed devnet transfer and peer disconnect.
- The separate Solana Testnet cluster returned the correct genesis and rejected
  a devnet blockhash. Testnet message signing passed. Its faucet returned
  `-32603`, so a funded transfer on that cluster was not verified.

The app compiles for generic iOS. No simulator, physical-device UI, native iOS
relay session, mainnet spending or third-party dApp swap was tested in this task.
Core/relay transfer checks are not evidence of every dApp or swap program.

## Delegate-review regression validation (6 November 2026)

The reported source, `7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca`, compared
token balances but omitted the token account's delegate and delegated amount.
Consequently, an approval with no immediate token transfer could look like a
fee-only transaction. The repair was applied to source base
`4505db54c09c0ceb79e9977d767200421a0f13b9`; it does not change transaction bytes
or remove the user's signing authorization.

`WalletConnectSolanaConsentRegressionTests` uses the production wire parser and
review implementation, with synthetic binary token accounts and an injected
RPC transport. With identical fees, balances, slot and programs, changing the
simulated delegate must change the review. The identical test failed on the
reported source (one expected assertion failure) and passed on the repair.
No validator or public network is involved in that test.

`WalletConnectSolanaPermissionTests` covers both token programs, direct and
checked approval, all three transaction methods, indirect permission changes,
lookup addresses, finite/zero/maximum allowances, replacement, revocation,
repeated approval, approve-then-revoke, multiple accounts of one mint, malformed
permission data, the inspection limit and stale consent. An ordinary transfer
still reports a decrease of 1,000 tokens; signed message bytes remain unchanged.

Validation on Xcode 27.2 (27B52), Swift 6.4.2:

- Focused Solana WalletConnect and stablecoin-recovery host checks: 42 passed,
  one opt-in live test skipped.
- Broader Solana and WalletConnect EVM host checks, with diagnostic sinks in
  separate processes as described below: 196 passed, ten opt-in live tests skipped.
- OathDiagnostics host checks: 119 passed in the main run; its isolated trace
  check also passed separately. One opt-in live check was not run.
- Localization validator: no findings; 24 localization-tool tests passed. The
  two added strings exist in all 57 languages; existing translations are unchanged.
- Public-source validation, diagnostics coverage and redacted secret scan passed.
- Unsigned generic iOS Release build passed.

The broad combined run exposed an existing test-process dependency:
`SolanaReadCancellationDiagnosticsTests` and `StablecoinSolanaRecoveryTests`
configure different sinks for the same configure-once diagnostics singleton.
Running them together produced the same two assertions in one test on both the
original source and the repair. The diagnostics class already documents its
separate-process requirement. Use separate invocations rather than changing
production singleton behavior or weakening assertions:

```sh
swift test --package-path Packages/OathAnkr --filter 'Solana|WalletConnectEVM' --skip StablecoinSolanaRecoveryTests
swift test --package-path Packages/OathAnkr --filter StablecoinSolanaRecoveryTests
swift test --package-path Packages/OathDiagnostics
OATH_TRACE_OUTBOX_TEST=1 swift test --package-path Packages/OathDiagnostics --filter DiagnosticTraceTests.testRecordCapturesContextBeforeDetachedUpload
python3 Tools/CheckLocalizationCatalog.py
python3 Tools/TestLocalizationCatalog.py
python3 Tools/ValidatePublicRelease.py
python3 Tools/CheckDiagnosticsCoverage.py
gitleaks dir . --redact=100 --no-banner
xcodebuild build -project OathAtmosphere.xcodeproj -scheme OathAtmosphere -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

For failed-before reproduction, create a detached worktree at the reported
commit, copy only `WalletConnectSolanaConsentRegressionTests.swift` into its
`Packages/OathAnkr/Tests/OathAnkrTests/` directory, and run `swift test
--package-path Packages/OathAnkr --filter WalletConnectSolanaConsentRegressionTests`
from that worktree. Its expected exit status is 1; on the repaired source it is 0.

These results establish the source-level repair and compilation, not installed
App Store behavior. No simulator, physical device, external dApp session, live
transaction, App Store upload or submission was performed for this repair.

## Deliberate limits

- Only canonical Solana CAIP-2 IDs; unknown cluster aliases are rejected.
- Legacy and v0 wire transactions up to 1,232 bytes; batches contain 1–8 items.
- Binary/invisible-control messages, future transaction versions and durable
  nonce transactions are not supported by this review path.
- Batch members are simulated individually. Dependent batches that require an
  earlier member to execute first can fail review; they are not blindly signed.
- The signer and every writable account must fit within the 64-account preview
  limit. Larger requests are rejected rather than silently truncating inspection.
- Changes to an existing token account's owner or close authority are rejected
  until a dedicated account-control review is available. This delegate review is
  not a decoder for every Token-2022 extension or arbitrary program permission.
- Failed simulations are rejected. Uncertain submission responses stay pending
  until network status or blockhash expiration resolves them.

## Reproduce

Run the `WalletConnectSolana` host tests in OathAnkr and
`WalletConnectSolanaJournal` tests in OathDatabase. `Tools/CheckMultiWallet.py
--solana-send` checks the vault authorization boundary.
`Tools/CheckWalletConnectNamespaces.py` checks the Swift/JS namespace validators.

Explicit opt-in live runs require an isolated funded devnet fixture in
`OATH_SOLANA_TESTNET_FIXTURE`, with its secret stored locally outside the repo,
and JS SDK dependencies in `NODE_PATH`:

```
python3 Tools/CheckWalletConnectSolanaLive.py
python3 Tools/CheckWalletConnectSolanaLive.py --relay
```

The relay runner reads the existing local WalletConnect project configuration.
It suppresses SDK logs and never prints pairing URIs, fixture secrets or signed
payloads. Shared app diagnostics report provider failures without request data.

Protocol references:
[Reown Solana RPC](https://docs.reown.com/advanced/multichain/rpc-reference/solana-rpc),
[Solana CAIP-2](https://namespaces.chainagnostic.org/solana/caip2),
[Reown Solana provider](https://github.com/reown-com/appkit/blob/main/packages/adapters/solana/src/providers/SolanaWalletConnectProvider.ts).
