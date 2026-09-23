# Robinhood mainnet integration preflight

Verified on September 12, 2026. Full app and notification support is **not enabled**.

## Verified reads

`test_robinhood_mainnet.py` performs real, read-only requests with no wallet secrets,
signing, broadcasting, or notifications. Seven mainnet tests passed:

- Official RPC and PublicNode both return chain ID 4663 (`0x1237`).
- A real wallet's current native ETH balance decodes without floating point.
- A real transaction and its receipt agree on hash, block, sender, success and fees.
- Canonical USDG and WETH contracts return the expected decimals and exact balances
  for a real pool address; the fixture holds a nonzero balance.
- Transfer logs for a bounded historical range match split-range reads and the
  transaction receipt. This verifies bounded history reads, not complete wallet history.
- PublicNode returns complete block receipts without ANKR for notification detection.
- Robinhood's stock-token registry returns unique mainnet contract identities and
  decimal-string corporate-action multipliers.

Sample wallet: `0x364c07cdd42733aac9a783a89c48df48fba38148`.

Sample transaction:
`0x625943fed76ba835bf7384d3338dd0e4fb7cc75620521e3b6a78cd0e29454d1d`.

## Blocking provider result

With the user-supplied ANKR key, all three required Advanced API methods reject
`blockchain: ["robinhood"]` with RPC code `-32602`, including the message
`robinhood is not allowed`:

- `ankr_getAccountBalance`
- `ankr_getTransactionsByAddress`
- `ankr_getTokenTransfers`

ANKR's documented Advanced API mainnet list does not include Robinhood. Enabling
the app's existing ANKR sync path for this chain would therefore create a broken
balance/history integration.

Blockscout v1/v2 API requests returned HTTP 403 browser challenges. PublicNode
archive balance, log and trace requests required a personal token. The official
RPC served historical logs but does not expose `debug_traceBlockByNumber`.
The standard RPC endpoints alone have not established complete wallet token
discovery, indexed address history, or internal-native-transfer coverage.

## Reproduce

```sh
python3 Scripts/test_robinhood_mainnet.py -v
ROBINHOOD_ANKR_KEY_FILE=/path/to/key-file python3 Scripts/test_robinhood_mainnet.py RobinhoodANKRReadinessTests -v
```

The first command skips the ANKR readiness test without a key file. The second
currently fails three subtests, deliberately exposing the unsupported methods.
Keys are read in memory and never printed or accepted as CLI arguments.
No assertion result should be described as full production support.

## Remaining integration

A verified indexed provider is required for comprehensive token discovery and
wallet history. Once available, validate pagination, error responses and exact
numeric decoding before adding network routing, account persistence, asset and
token discovery, prices, receive/send, transaction status, and notifications.
Stock-token valuation must account for the registry's share-per-token multiplier.
Notification providers must remain independent of ANKR, including pricing and
internal transfers. Existing token visibility and user notification preferences
continue to apply.

## Sources

- https://docs.robinhood.com/chain/connecting/
- https://docs.robinhood.com/chain/contracts/
- https://docs.robinhood.com/chain/stock-token-apis/
- https://robinhood.publicnode.com/
- https://www.ankr.com/docs/advanced-api/overview/
