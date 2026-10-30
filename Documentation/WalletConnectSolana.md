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
distinguishes signing from broadcasting. Simulation is an estimate, and partial
account inspection is disclosed. Unknown metadata remains a mint address;
missing decimals display raw units rather than an invented token amount.
Testnet metadata never uses a same-address mainnet token label.

The reviewed wire message, blockhash, fee instructions, lookup tables and other
signers' signatures are preserved. Fresh authentication and the selected Solana
derivation are checked at signing. Changed simulation results require renewed
confirmation. Version 0 address lookup tables are resolved on the selected
cluster. Broadcasts require all necessary signatures and cannot skip preflight.

Before broadcasting, the exact signed bytes and signature are committed to
`walletConnectSolanaSubmissions`, with wallet/account ownership, cluster,
fingerprint, reset guards and deletion cascades. Retries replay those bytes and
never sign a replacement. The bounded worker survives sheet dismissal and
resumes on unlock after suspension/relaunch. It updates visible results and
plays success feedback on confirmation. iOS suspension still stops execution;
this is not an always-running background service. Test-cluster submissions do
not enter the mainnet transaction history or mainnet balance refresh path.

## Verification

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

## Deliberate limits

- Only canonical Solana CAIP-2 IDs; unknown cluster aliases are rejected.
- Legacy and v0 wire transactions up to 1,232 bytes; batches contain 1–8 items.
- Binary/invisible-control messages, future transaction versions and durable
  nonce transactions are not supported by this review path.
- Batch members are simulated individually. Dependent batches that require an
  earlier member to execute first can fail review; they are not blindly signed.
- At most 64 accounts are inspected per simulation; incomplete previews say so.
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
