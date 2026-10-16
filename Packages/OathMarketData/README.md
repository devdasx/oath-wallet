# OathMarketData

Public market data shared by Home, token discovery and asset details. Requests contain only public network/token identities, never a wallet account, name, secret or transaction.

## Contract prices

`MarketDataService.quote` races exact-identity Coinbase and CoinGecko quotes with GeckoTerminal, DEX Screener and DefiLlama. The first valid quote is saved atomically with the portfolio price. Providers are independent; missing listings and slow metadata/chart requests do not prevent other price providers from completing.

- Network and contract/mint/coin-type identity must match. Symbol-only search is never used. Canonicalization follows the chain's address rules.
- DEX Screener's USD price belongs to its base token, never the quote token. Select the deepest matching pool with at least USD 1,000 liquidity. GeckoTerminal also requires at least USD 1,000 reported reserve.
- DefiLlama requires confidence of at least 0.9. Provider decimals, where available, must match; XRP issued currencies retain the app's separate 96-place accounting scale.
- CoinGecko and DefiLlama timestamps must be within 15 minutes, with at most two minutes future skew. Pool providers without quote timestamps use retrieval time, not an inferred trade timestamp.
- A 12-second race deadline bounds waiting. Shared public requests retain work while another consumer needs it and cancel abandoned requests. Per-host pacing, response limits, coalescing, cooldowns and bounded queues remain in effect.
- Valid persisted prices from every chain can be used offline. Refresh failures retain the original timestamp. A slower provider never replaces a newer displayed observation. Unknown prices remain unavailable, never an invented zero or assumed stablecoin peg.
- Token addition starts a quote fetch without delaying navigation. Price loading is independent of chart and information loading; the existing visible-detail refresh runs once a minute.

The network mapping covers all 31 token-capable networks. Coverage is not a promise that every contract has a liquid public market. Native assets use the existing explicit project map; unmapped identities are never resolved by a matching ticker.

Provider references:
- https://docs.dexscreener.com/api/reference
- https://api.geckoterminal.com/docs/index.html
- https://api-docs.defillama.com/
- https://docs.coingecko.com/reference/simple-token-price

## Validation

Host regression tests cover provider isolation, wrong chain/contract/base-token rejection, casing, decimals, tiny prices, stale observations, cancellation, queue capacity, cache persistence and primary-provider outages. Optional live tests use public token references only. Reports for the October 16 validation are in `output/token-price-validation` at the repository root. Public network results are time-specific; missing/throttled quotes are recorded explicitly.

Transport and fallback failures use the shared OathDiagnostics pipeline. Optional absent listings and expected cancellation are excluded; the exact GeckoTerminal missing-token envelope is covered by diagnostics tests. No simulator, device, wallet signing or transaction broadcast is needed for these checks.
