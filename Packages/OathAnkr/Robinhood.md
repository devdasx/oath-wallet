# Robinhood mainnet integration

Status checked on 2026-10-12. Network ID is `robinhood`, EVM chain ID is **4663**
(`0x1237`), and the gas asset is **ETH**, with 18 decimals. This does not use
Robinhood testnet or a token named HOOD.

## Provider boundary and configuration

ANKR's `robinhood_mainnet` RPC works. Its Advanced account methods reject both
`robinhood` and `robinhood_mainnet` as unsupported blockchain arguments. RPC alone
does not provide an exhaustive owner token list or address transaction history.
Scanning the entire chain on a phone would not be a reliable substitute.

The implementation uses:

- ANKR for the chain ID, canonical block, native balance, batched ERC-20
  `balanceOf`/`decimals`, and transaction receipts.
- Robinhood's official Blockscout index, via
  `https://api.blockscout.com/4663/api/v2`, for paginated ERC-20 discovery,
  transactions, token transfers, and internal native transfers.
- Coinbase for ETH/USD. CoinGecko contract-to-project mappings and USD quotes
  for listed tokens. DEX Screener is a secondary source for exact-contract,
  liquid base-token pairs. Symbols are never used as token identity.

The official explorer's public endpoint returned HTTP 403 in this environment;
the Pro API returned HTTP 402 without a key. Blockscout offers a free API tier,
but **a Blockscout key has not been supplied**. Full automatic discovery and
history are therefore implemented but not activated or live-validated here.
Native ETH and manually added/cached token balances work with ANKR alone.
Incomplete discovery is recorded as incomplete, never as a successful empty
wallet. Existing data survives provider failures.

Credentials belong only in the ignored `OathApp/Private/TokenRPC.plist`:
`AnkrAPIKey` and optional `BlockscoutAPIKey`. Configure the index key without
putting it in shell history:

```sh
python3 Tools/ConfigureTokenRPC.py --provider blockscout
```

Rebuild after configuration. No credential is stored in the database, fixtures,
source-controlled files, or diagnostic output. Receive guidance uses manual
token tracking copy until the index is configured.

## Data flow and persistence

Independent balance, metadata, price, and history work overlaps using Swift
structured concurrency. RPC batches contain at most 30 calls, with at most four
in flight. Blockscout requests are separately serialized and paced for its
5-request/second free tier. CoinGecko catalog requests coalesce and cache for a
day; token prices are requested in batches of up to 30 contracts.

Balance reads use one block number and verify its hash again after the batches.
Balances use integer strings throughout; metadata decimal mismatches or reverting
contract calls retain the previous amount. Unknown prices remain unknown in
storage; no invented quote or 1:1 conversion is written. A token with no reliable
market cannot be promised a real USD price. Previously successful quotes remain
available offline.

Schema migration `v23_robinhood_ledger` adds account-scoped sync state, exact
holdings, independent history cursors, parsed events, and original response
archives. The existing asset/price/activity tables feed the home portfolio,
sorting, asset details, local-currency valuation, and transaction history.
Wallet reset removes these account records while retaining public prices and
app preferences.

History has separate external-transaction, ERC-20, and internal-transfer streams.
Each stream has a recent window with overlap and a resumable older backfill.
Page data and cursor updates commit together. Duplicate pages upsert stable
event identities. Expired index cursors can replay their window once; failed
requests never mark a stream complete. Receipt chain ID, transaction identity,
block, transfer logs, and exact native fees are checked before publication.
Pending external transactions with no block timestamp are revisited at the
head after confirmation; they are not projected as confirmed history.

Only CoinGecko-listed exact contracts or tokens explicitly added by the user
appear in the portfolio, preserving the existing unverified-token filtering.
Receive, EVM derivation, private-key import/export, backup metadata, and token
contract search share the existing EVM implementation. Existing full-scope EVM
wallets gain Robinhood using the same public address and derivation path;
deliberately narrow imports retain their scope. Send/sign/broadcast remains
outside this balance/history integration.

## Verification evidence

Read-only mainnet testing used public addresses, never a user's wallet secret:

- `0x8366a39cc670b4001a1121b8f6a443a643e40951`
- `0xec9aa0a6c2372131a0502aba6188269ab52cacb5`
- `0xe5e702641ea86f4ae6cc3cdaed2b886f976be044`

The production Swift client read ETH plus 20 sampled funded token contracts for
each address. The production synchronizer persisted those 60 token holdings
and available prices, and reopening the database produced matching offline
holdings. Coinbase ETH and CoinGecko token prices passed live reads. The fixture
contracts are public samples discovered from on-chain transfer logs and the
CoinGecko Robinhood contract list; they are not an exhaustive wallet inventory.

Fixture tests cover pagination, receipt verification, exact quantities beyond
JavaScript's safe integer range, wrong networks, reorganization during a balance
snapshot, malformed responses, stale writes, partial failures, zero reconciliation,
history resumption, expired cursors, filtering, wallet isolation, and reset.
The generic iOS build and host package tests passed. No simulator or physical
device was launched.

Repeat the live production checks:

```sh
python3 Tools/CheckRobinhoodLive.py --run
# After supplying the Blockscout key:
python3 Tools/CheckRobinhoodLive.py --run --require-index
```

**Not verified:** live Blockscout discovery/history or an independent explorer
balance comparison, because the required index key is absent. DEX Screener and
the official public RPC returned HTTP 403; their availability is not counted as
a successful live fallback. Index fixtures validate parsing and safety behavior,
not access to the deployed service. No claim of universal token price coverage
or zero possible bugs is made.

## Primary sources

- [Robinhood network configuration](https://docs.robinhood.com/chain/add-network-to-wallet/)
- [ANKR Robinhood launch and RPC limits](https://www.ankr.com/docs/changelog/robinhood-chain/)
- [ANKR Advanced API coverage](https://www.ankr.com/docs/advanced-api/overview/)
- [Blockscout Robinhood API](https://github.com/blockscout/docs/blob/main/robinhood-api.mdx)
- [Blockscout API schema](https://github.com/blockscout/blockscout-api-v2-swagger/blob/main/swagger.yaml)
