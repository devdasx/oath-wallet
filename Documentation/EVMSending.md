# EVM sending and the Arbitrum review-screen fix

## Cause and integration

The Arbitrum review screen reached `sendUnsupported` because `supportsSend` and
`OathTrackedSendChain` had no generic EVM adapter. Arc was the only EVM chain with
an authenticated send implementation. The screen therefore never requested an
Arbitrum fee quote.

`EVMSendNetwork` now defines the chain identities and fee policies for Ethereum,
Arbitrum, Avalanche, Base, BNB, Fantom, Flare, Somnia, Story, Gnosis, Linea,
Optimism, Polygon, Monad, Unichain, HyperEVM, Robinhood, Scroll, Taiko, Telos, and
X Layer. Arc retains its USDC-gas implementation. All other send adapters remain
in place.

The flow starts quote preparation when Continue is tapped. Independent balance,
nonce, token-decimals, and gas-price reads overlap with a bounded concurrency
limit. Providers supply state and estimates; destinations and ERC-20 transfer
calldata are constructed locally. Transactions use replay-protected EIP-1559 or
EIP-155 signatures. Every provider is checked against the expected chain ID;
broadcast additionally verifies the provider before sending signed bytes.

A fresh passcode/biometric authorization gates signing. The exact signed payload
is committed before broadcast. The durable status worker resumes on application
restart, checks receipt inclusion and network finality, and rebroadcasts only the
same signed bytes when acceptance is unknown. A successful broadcast is shown
as submitted, not confirmed. Errors never manufacture success.

## Fees and provider differences

- Arbitrum's `eth_estimateGas` includes the parent-chain publication cost. It is
  not added again. [Arbitrum documentation](https://docs.arbitrum.io/build-decentralized-apps/troubleshooting-building)
- Base, Optimism, and Unichain reserve execution, L1 data, and operator fees using
  the GasPriceOracle. The extra reserve is displayed before authorization; actual
  receipt fees replace the estimate. [OP fee documentation](https://docs.optimism.io/op-stack/transactions/fees)
- Scroll uses its L1 fee oracle in addition to execution gas.
  [Scroll documentation](https://docs.scroll.io/en/developers/transaction-fees-on-scroll/)
- Linea uses `linea_estimateGas`, without a provisional gas-price cap that can
  reject the node's own calldata-aware recommendation. ANKR returned method-not-
  found during validation, so the official mainnet RPC is a chain-checked fallback.
  Execution rejections are not retried as unsupported methods.
  [Linea documentation](https://docs.linea.build/api/reference/linea-estimategas)
- HyperEVM's latest-state restriction is respected. An unknown transaction stays
  in tracking; historical nonce searches are not used to invent a replacement.
  [HyperEVM RPC documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/json-rpc)

Max reserves native gas even when the selected asset is a token. All atomic
amounts use checked uint256 decimal-string arithmetic. Token decimals are read
from the contract before signing. A false-return or reverting token simulation
blocks submission. Actual recipient delivery is derived from Transfer logs,
separately from execution status, to handle transfer-tax tokens.

## Persistence

Migration `v48_evm_send` adds `evmSendPlans`, linked to the existing send journal.
Existing status-job triggers and the indexed scheduling queue handle new EVM
sends. Source reservations cover duplicate imports of the same address/network.
Local activity placeholders are removed when matching indexed transfers arrive,
without altering individual event amounts.

Confirmed/failed sends refresh native and selected-token balances from RPC. The
four dedicated EVM portfolio inventories are updated in the same database write.
Older inventory responses cannot overwrite the newer post-send holdings. Reset
guards, deletion cascades, shared diagnostics, and the common retry budgets apply.

## Validation performed, 2026-10-14

- Generic iOS compilation; no simulator or physical device was launched.
- Independent ethers signing vectors for native and ERC-20, typed and legacy
  transactions; wrong-owner, altered-payload, chain-binding, and overflow tests.
- Mocked RPC quote/sign/status tests across every registered network, including
  native/token Max, chain/ID mismatches, provider fallback, Linea, L2 fees,
  pending nonces, failed execution, finality, cancellation, and replacement.
- Loopback Ganache execution using production Swift construction/signing:
  ETH to an externally owned account and a payable contract, ERC-20, token Max,
  native Max, duplicate submission, reverting recipient, and false-return token.
  Exact recipient/sender balance changes and receipt fees were checked.
- Database reopen, same-address reservation, tracking-job completion, dedicated
  portfolio refresh, stale-inventory rejection, and indexed activity tests.
- Host authorization checks use the production vault/passcode/imported-key signer;
  OS biometrics and HD derivation are fixtures in that harness.
- Live read-only chain/state/status-method checks on all 21 networks. Real fee
  quotes passed on 20, including Arbitrum and Linea. Telos had no funded public
  sender among the bounded block samples; its live fee quote remains unverified.
- Shared diagnostics privacy/coverage checks and host package regression suites.

These checks are not public-mainnet/testnet broadcast evidence. No user funds
were spent and no public transaction was broadcast for this fix. Ganache does
not reproduce each L2 sequencer or oracle. iOS decides when suspended background
work executes; persistent jobs resume when the app receives execution time.
