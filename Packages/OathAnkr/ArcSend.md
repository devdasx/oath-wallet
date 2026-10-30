# Arc sending

The app supports native USDC and ERC-20 transfers on Arc mainnet. It uses the
existing recipient, amount, fee review, vault authorization, submission and
transaction-history flow. App signing accepts mainnet plans only; isolated test
harnesses explicitly select Arc Testnet, with keys outside the repository.

## Units, preparation and signing

- Native USDC and gas use **18 atomic decimals**. The USDC ERC-20 mirror at
  `0x3600000000000000000000000000000000000000` has six decimals but represents the
  same balance. Imports normalize it to the one native asset; it is never counted
  twice. Other ERC-20 contracts use their on-chain decimals.
- Every RPC batch verifies the network on that provider. Mainnet is chain 5042;
  testnet is 5042002. Blockdaemon, dRPC and Arc public endpoints provide bounded
  independent fallbacks. Deterministic RPC rejection retains its signed error
  code and does not retry other providers.
- Independent nonce, balance, token metadata and gas-price reads overlap behind
  four request permits. Quotes pin state to a recent block, verify its hash, and
  simulate the final transfer before authorization. Pending external nonces,
  changed decimals, insufficient funds, false token returns, contract reverts,
  stale blocks, wrong networks and excessive fees fail closed.
- EIP-1559 messages are built locally with exact uint256 arithmetic. Native Max
  reserves the maximum USDC gas charge; token Max sends the token balance while
  retaining enough USDC for gas. Quotes authorize at most 2,000,000 gas and 1 USDC
  in fees, expire after 90 seconds, and are rechecked before signing.
- The fee shown in review is the maximum authorized fee. Settlement replaces it
  with `gasUsed * effectiveGasPrice`. Max may leave the unused fee reserve.
- The existing HD derivation path or imported key signs locally with secp256k1.
  The vault checks the selected account, immutable queued plan, passcode or
  biometric authorization and authentication generation. Signature recovery and
  exact message reconstruction verify the owner, chain, nonce, recipient, asset,
  amount and fee bounds before persistence.

This is a fungible transfer path, not NFT, multisig, smart-account or arbitrary
contract execution. ERC-20 success/no-return conventions are supported. Frozen,
restricted or otherwise reverting transfers cannot proceed. Nonstandard token
taxes are not quoted as a guaranteed recipient amount: confirmed Transfer events
record actual delivery, separately from EVM execution success, so a successful
partial delivery is never incorrectly described as a failed network transaction.

## Persistence and recovery

Migration `v44_arc_send` adds `arcSendPlans`, keyed by the send foreign key. The
existing active-source index and indexed due-status queue are reused. Reservation
is exclusive across duplicate wallet imports of the same source. Exact signed
bytes are persisted before broadcast; recovery never signs a new transaction.

RPC acceptance is not finality. The worker verifies the matching transaction,
canonical inclusion block and finalized height before recording confirmed or
failed execution. A finalized consumed nonce triggers a bounded binary search to
identify a replacement or self-transfer cancellation. Unknown or pruned history
retains the saved transaction and retries the same bytes. EVM transactions have
no automatic age expiry, so a timeout cannot release a signed reservation.

Final settlement updates fees, status and token delivery, removes the tracking
job, and requests balances at or beyond the settlement block. Archive hydration
does not create a second activity row for locally sent transactions. The existing
worker resumes saved work on reopening; iOS controls execution while suspended
or force-quit. No continuous force-quit execution is promised.

Failures use OathDiagnostics, task-local chain/operation context, DiagnosticHTTP
and the shared outbox. No new error destination was introduced. Cancellation,
null pending transaction/receipt results and alternative JSON representations are
expected control flow. No keys, raw signed transactions, request parameters or
full provider URLs are uploaded in diagnostics.

## Verification on 2026-10-14

Passed:

- Generic iOS compilation (`OathAtmosphere`, signing disabled). No simulator or
  physical device was launched; runtime/visual checks were not performed.
- Eleven host signing/provider tests, including four independent ethers EIP-1559
  vectors (native/ERC-20, mainnet/testnet), exact uint256 arithmetic, wrong-chain
  replies, envelope IDs, negative RPC codes, Max, fee bounds, receipt matching,
  token delivery, finality, replacement, cancellation and idempotent replay.
- Real transactions on an isolated local EVM using the production Swift client
  and signer: native transfer, ERC-20 transfer, token Max and native Max. Exact
  recipient/sender balance changes and actual gas charges were asserted. False
  token returns and reverting recipients were rejected before signing.
- Real local-EVM restart recovery: reopen a SQLite journal containing a signed
  transaction, let the actual worker broadcast it, confirm it, and verify that
  the saved transaction is confirmed and the status queue is empty.
- Twenty-one targeted database/status tests, with one separate opt-in public
  archive test skipped. Five Arc journal tests cover durable signatures, source
  exclusivity, terminal outcomes, actual token delivery, history merging and
  balance-refresh evidence.
- Nine vault authorization host checks. They execute the real vault/PIN and
  imported-key signing path with a synthetic biometric store; HD derivation and
  hardware biometric interactions were not exercised by that host harness.
- Forty-two diagnostics host tests passed, two opt-in runtime tests skipped;
  diagnostics coverage guard passed with 371 observed catch sites.
- **Public Arc Testnet read-only preparation passed**: chain 5042002, native USDC
  quote/preflight/simulation, finalized-block lookup and EURC six-decimal metadata.
  The last observed native fee ceiling was 945,000,000,000,000 atomic USDC for
  21,000 gas. This was unsigned simulation, not a transfer.

**Not yet verified:** funded signing, broadcast and settlement on public Arc
Testnet. Circle's faucet blocked this computer, and the isolated test wallet
remained unfunded. Local EVM execution is not evidence of public Arc broadcast.
The public tests below remain pending until free test USDC and EURC are supplied.

## Repeatable checks

```sh
swift test --package-path Packages/OathAnkr --filter 'ArcSendTests|ArcSendRPCRegressionTests'
swift test --package-path Packages/OathDatabase --filter 'ArcSendJournalTests|ArcLedgerTests|SendStatusTrackingTests'
python3 Tools/CheckMultiWallet.py --arc-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`Tools/GenerateArcSendVectors.cjs` reproduces the ethers reference vectors.
`Tools/PrepareArcLocalFixture.cjs` starts the loopback EVM fixture (requires
ethers, Ganache and solc at the temporary dependency paths in that tool). Use
`OATH_ARC_LOCAL_EVM=1` to opt into `ArcLocalSendIntegrationTests` and
`testArcLocalEVMRestartRecovery`. Run recovery before the native Max test, or
restart the fixture between them; they spend the same isolated test balance.

Public read-only test:

```sh
OATH_ARC_PUBLIC_QUOTE=1 swift test --package-path Packages/OathAnkr \
  --filter testPublicTestnetFeeAndNetwork
```

For funded tests, provide a mode-0600 JSON fixture outside the repository with
`privateKey`, `sender` and `recipient` for newly generated test-only accounts.
Fund the sender with free Arc Testnet USDC and EURC through Circle's faucet, then
run sequentially (token Max spends the fixture's EURC balance):

```sh
OATH_ARC_TESTNET_FIXTURE=/tmp/oath-arc-testnet-fixture.json \
  swift test --package-path Packages/OathAnkr --filter testLiveNativeTokenAndMax
OATH_STATUS_LIVE=1 swift test --package-path Packages/OathDatabase \
  --filter testLiveArcResumesJournalAfterRestart
```

The second test uses the same fixed temporary fixture path. These tests sign with
the production Swift implementation and verify exact balance effects, actual
fees, terminal receipts, replay behavior and database restart recovery. They do
not invoke a mainnet or user wallet.

## Official references

- [Arc networks and RPC endpoints](https://docs.arc.io/arc/references/connect-to-arc)
- [Arc gas and fees](https://docs.arc.io/arc/references/gas-and-fees)
- [USDC and EURC contract addresses](https://docs.arc.io/arc/references/contract-addresses)
- [Circle testnet faucet](https://faucet.circle.com)
