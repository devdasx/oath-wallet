# WalletConnect readable transaction details

## Presentation boundary

The EVM transaction-data destination now opens a structured review. It shows the
network, sending account, destination, native value, recognized contract fields,
router steps and deadline. Original immutable calldata is one navigation step
away, selectable in a technical view. THORChain details retain their decoded
amounts, account, destination and memo; the original signing document is collapsed.
Neither view edits a request or signs anything.

Token amounts use on-chain decimals when available. Missing precision remains
explicit exact units; there is no guessed 18-decimal fallback for tokens. Token
names are sanitized metadata, never a contract safety guarantee. Metadata lookup
is limited to 12 distinct tokens, cancellation-aware and routed through shared
diagnostics. Unknown ABI, absent optional metadata, reserved commands and parser
budget exhaustion are expected presentation inputs, not diagnostic failures.
No calldata, addresses, metadata text or signing payload enters diagnostics.

## Decoding coverage

Standard ERC-20 transfer/approval, NFT operator approval, safe NFT transfer and
existing verified V3 single-pool swaps keep their conservative interpretation.
The new router decoder supports known Uniswap V2 Universal Router and PancakeSwap
Universal Router deployments with exact-input/output V2/V3 paths, Permit2 transfer,
sweep, transfer, native wrapping/unwrapping, balance checks and nested subplans.
Recipient aliases and router-balance sentinels are resolved for display. Optional
steps are visibly identified. Unknown steps remain visible, with a warning that
the summary is incomplete. Function-selector matches alone never identify a DEX.

Canonical ABI lengths, zero padding, address widths, boolean values, dynamic
offsets and array lengths are checked. Input is already capped by the request
parser; command count is capped at 64 and nested expansion at three levels.
Unrecognized routers, V4 command payloads, signatures embedded in unknown commands,
and arbitrary contract ABIs are not claimed to be decoded. This is a request
summary, not simulated balance changes or a guarantee of execution.

The same EVM page is used by every dApp and every EVM network offered by the app.
Current WalletConnect transaction namespaces are EVM and THORChain. Ordinary send
support on another chain is not WalletConnect transaction support for that chain.

## Primary references

- https://github.com/Uniswap/universal-router/tree/main/deploy-addresses
- https://github.com/Uniswap/universal-router/blob/main/contracts/base/Dispatcher.sol
- https://developers.uniswap.org/docs/protocols/universal-router/concepts/commands
- https://developer.pancakeswap.finance/contracts/universal-router/addresses
- https://github.com/pancakeswap/infinity-universal-router/blob/main/src/base/Dispatcher.sol

Deployment entries are scoped to chain plus address. Add another router/version
only after checking its command ABI and deployment; do not trust dApp-supplied
branding or a public selector-name lookup as proof of contract semantics.

## Reproducible validation

`Tools/GenerateWalletConnectCallVectors.cjs` uses the independent ethers ABI
encoder. `WalletConnectCallDetailsTests` covers exact-input/output, nested steps,
optional failures, sentinels, malformed/truncated input, unknown commands, wrong
chain/address and immutable signing bytes. Existing signature vectors cover the
unchanged transaction signer. The app build is a generic iOS build, without a
simulator or device launch.

`Tools/CheckWalletConnectDEXLive.cjs` is explicitly isolated to Sepolia and the
existing test-only fixture. It verifies real Uniswap and PancakeSwap swaps using
new test-token liquidity, not a mock exchange. All swaps use the production Swift
WalletConnect parser, quote, preflight, signer, broadcast and readable decoder.
Pool creation is separate ethers fixture setup because it exceeds the app gas
cap. Each receipt and balance effect is independently read from the chain.
The runner limits per-call and total test ETH spending, journals before waiting,
and stops on an unresolved in-flight transaction. It does not test the browser,
WalletConnect relay, UI authentication or all dApps/tokens. Public run evidence is
stored separately from private fixture keys and signed journals.

Run that harness with `NODE_PATH=<ethers-and-solc-node_modules> python3
Tools/CheckWalletConnectTransactionsLive.py --dex`. The local fixture must be
funded with test ETH; never substitute a real wallet. Existing completed checks
are retained in its local evidence file. A receipt-only setup operation is not
marked as a verified balance effect.

## Validation on 16 October 2026 (Asia/Hebron)

The generic iOS build passed without launching the app. The WalletConnect host
suite passed (32 executed, one opt-in live test skipped), including eight readable
decoder tests with 16 independently encoded ABI vectors. Standard token transfer
presentation was checked across all 23 `EVMSendNetwork` cases. The separate
authorization/durable-retry harness passed 40 host checks. Localization validation
and the diagnostics coverage guard passed. Diagnostics host results: 50 executed
checks passed, two opt-in tests skipped.

Actual public Sepolia swaps used the official Uniswap and PancakeSwap Universal
Routers and their V3 pools, with isolated OWCT/WETH test liquidity. All four
directions (token to native and native to token on each router) confirmed, with
independent balance-effect checks and completely decoded nested request data.
These exercised production Swift parsing, fee preparation, preflight, signing and
broadcast. Pool provisioning was separate test setup and did not relax app limits.

Additional public testnet transfers exercised production send/status cores and
reopened local database settlement:

| Network | Confirmed coverage |
| --- | --- |
| Aptos testnet | Native APT, Coin token, Fungible Asset token |
| Solana devnet | Native SOL, SPL token, Token-2022 token, transfer-fee token |
| Stellar testnet | Native XLM and classic issued token |
| Sui testnet | Native SUI |
| TON testnet | Native TON and jetton |
| TRON Nile | Native TRX, TRC-10 and TRC-20 |
| XRP Ledger testnet | Native XRP, issued currency and MPT |
| Bitcoin Cash chipnet | Native BCH, including recovery of the saved test transaction |
| Litecoin testnet | Native LTC |

The first UTXO fixture lookup missed funds moved to test index 900 by prior runs;
the test now includes those controlled receive/change addresses. A replaced
Solana fixture lacked its token mints; test mints were provisioned again. Public
Solana throttling was resolved for this run by pacing the remaining test cases.
These were test setup fixes, not changes to production address discovery.

Not passed: Bitcoin testnet4 and Arc fixtures lacked spendable funds; the Dogecoin
testnet provider was unavailable; NEAR native/token status calls timed out without
confirmation. Stellar contract-token preparation returned a valid resource fee
above Oath's 1 XLM limit. That uncovered a real error classification bug: excessive
fees were incorrectly reported as malformed data. The app now reports the fee
limit accurately, with a regression test, and retains the limit. No contract-token
transfer is claimed to pass for Stellar in this run.

Public hashes and machine-readable results are in
`output/walletconnect-readable-validation-2026-10-16.json`. No fixture secrets or
signed journals are included. Send/status receipts establish successful execution
and database settlement; the DEX checks additionally verify balance changes.

No simulator, physical device, dApp browser, or WalletConnect relay/UI test ran in
this validation. There is no claim that every dApp, arbitrary contract, token,
V4 route, network, or mainnet transaction has been tested. Shared EVM presentation
coverage does not establish on-chain compatibility for every deployment.

## Approval-screen swap summary repair (16 October 2026)

The approval view previously consulted only `WalletConnectEVMAction`, whose swap
classification covered three single-pool V3 deployments. Universal Router decoding
and token metadata were available only after opening Transaction details. As a
result, even a fully decoded Universal Router swap appeared as a generic contract
interaction on the screen where the user approved it. Network information was
below the account rather than alongside the exchanged assets.

`WalletConnectSwapReview` now feeds both approval and details. It preserves each
route's input, output, exact/minimum/maximum bound, recipient, payer and optional
status. The approval shows the request network above the review and alongside both
assets, contract identities and decimal amounts. Metadata uses the same chain-
validated identity service and artwork pipeline, at most three concurrent lookups
and twelve tokens. Missing metadata retains explicit raw units and the contract;
precision and names are never guessed. The original signing bytes are unchanged.

A single fully decoded, non-optional Universal Router route can fold adjacent
wrap/unwrap steps only when the chain's wrapped-native contract and router
recipient/payer agree. Native input shows the wallet's maximum contribution;
native output shows the unwrap command's own minimum. Unrelated wrappers, optional
subplans, unknown steps and multiple routes retain separate conversion steps.
Split routes are displayed individually, never summed into an invented quote.
V3 Router02's zero-input router-balance sentinel is not shown as zero tokens.

Direct V2 Router02 swaps are also decoded for the documented PancakeSwap deployments
and Uniswap Ethereum Router02: exact input, exact output, token/native directions,
and fee-on-transfer variants. Canonical array offsets, counts, address widths,
lengths and nonpayable token inputs are validated. THORChain's receive network is
now visible in the main review instead of only in its details destination.

Additional primary references checked for this change:

- https://developer.pancakeswap.finance/contracts/v2/addresses
- https://github.com/Uniswap/v2-periphery/blob/master/contracts/UniswapV2Router02.sol
- https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/interfaces/IV3SwapRouter.sol
- https://github.com/Uniswap/universal-router/tree/main/script/deployParameters
- https://github.com/pancakeswap/infinity-universal-router/tree/main/script/deployParameters

Unknown routers, V4/Infinity payloads and arbitrary contract calls are still not
claimed to reveal a complete swap. The primary approval now explicitly discloses
incomplete decoding. This change does not invent output tokens from dApp branding,
selector databases, or unrelated quoted prices, and does not alter authorization,
fees, simulation, signatures or submission.

Validation: 43 WalletConnect host tests passed, one opt-in live test skipped.
The deterministic independent ABI generator now has 34 vectors. The four earlier
Sepolia swap transactions were fetched again using read-only RPC, their successful
receipts rechecked, and their actual calldata replayed through the new review in
host tests (`Fixtures/WalletConnect/confirmed-swaps.json`). This is replay of
confirmed transactions, not four new submissions or UI/relay end-to-end testing.
