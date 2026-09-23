# Official Network Logo Sources

The network-selection artwork in `EVMWallet/Assets.xcassets/NetworkLogo*.imageset`
was downloaded from each network's official website or official brand repository.
The assets are bundled with the application so network filters render immediately,
work offline, and do not depend on a third-party URL remaining available.

| Network | Official source |
| --- | --- |
| Bitcoin | https://bitcoin.org/en/ |
| Bitcoin Cash | https://bitcoincash.org/graphics/ |
| Litecoin | https://litecoin.com/ |
| Dogecoin | https://dogecoin.com/ |
| Ethereum | https://ethereum.org/assets/ |
| TRON | https://tron.network/resources/?lng=en |
| Solana | https://solana.com/branding |
| BNB Smart Chain | https://www.bnbchain.org/en/brand-guidelines |
| Arbitrum | https://arbitrum.io/brand-kit |
| Base | https://brand.base.org/ |
| Polygon | https://polygon.technology/brand-guidelines |
| Optimism | https://www.optimism.io/brand |
| Avalanche | https://support.avax.network/en/articles/4132288-avalanche-brand-assets |
| Gnosis | https://www.gnosis.io/press |
| Linea | https://linea.build/assets |
| Scroll | https://scroll.io/brand-kit |
| Arc | https://arc.io (site favicon; 2026-09-18) |
| Taiko | https://taiko.xyz/brand-assets |
| Telos | https://telos.net/branding |
| X Layer | https://web3.okx.com/xlayer |
| XRP Ledger | https://xrpl.org/docs/introduction/what-is-xrp |

Retrieved July 25, 2026.

## User-approved replacements

The bundled artwork for Polygon, TRON, Ethereum, BNB Smart Chain, Arbitrum,
Base, Avalanche, Gnosis, Dogecoin, and Litecoin was subsequently replaced
with the application owner's supplied artwork on July 25, 2026. The replacements
retain the existing centralized asset names, so every network chip, native-coin
logo, and token network badge resolves the same approved bundled artwork.

## Contract-token artwork

The EVM top-token catalogs contain 1,856 admitted contract identities across
the 13
supported ANKR Advanced API mainnets. `Scripts/vendor_evm_token_logos.py`
validates every published artwork URL with an HTTP 200 response, decodes it,
converts it to a bounded PNG, and stores it in `EVMWallet/TokenLogos` using the
blockchain plus normalized contract address as the filename.

The current deterministic audit is stored in
`EVMWallet/EVMTopTokenCatalogs/LogoAudit.json`: 1,422 identities have verified
bundled artwork and 434 identities have no usable published contract-bound
artwork. Those entries intentionally use the neutral non-logo fallback instead
of a symbol-derived or cross-contract image. ANKR thumbnails remain permitted
only for custom or held/activity tokens that are absent from the bundled
catalog.

At runtime, contract identity produces the exact folder-relative PNG name. The
shared logo view resolves that file in the `TokenLogos` bundle directory,
decodes a display-sized thumbnail, and caches it. It does not pass the
folder-relative path to SwiftUI as an asset-catalog name.

## Solana token catalog

`EVMWallet/SolanaTokenCatalog.json` contains 109 admitted Solana-ecosystem
assets captured from CoinMarketCap. Every SPL mint in the
catalog was validated against Solana mainnet through ANKR, including its
on-chain decimal precision, and then required to be Jupiter-verified,
non-suspicious, and backed by positive liquidity. Its 108 contract-token logos
are bundled in
`EVMWallet/TokenLogos`; native SOL uses the bundled official Solana brand mark.
The bundled runtime catalog contains only the identity, ranking, decimal, and
logo fields the app reads. The complete provider response and validation
metadata are retained outside the app bundle in
`CatalogSources/SolanaTokenCatalogAudit.json`.

## Token safety admission

Catalog size is a maximum candidate count, not a trust signal. The build tools
apply chain-specific safety rules and record every exclusion in
`CatalogSources/TokenCatalogRemovalAudit.json`. Strong scam signals are also
written to `EVMWallet/TokenCatalogDenylist.json` so the app can reject them at
decode, provider, custom-token, and persistence boundaries.

TRON catalog entries are limited to TRC-20 assets with positive market cap and
TRONSCAN VIP or level-2 trust. Solana entries require Jupiter verification,
positive liquidity, a matching decimal definition, and no suspicious audit.
EVM scanner entries that ANKR does not whitelist are excluded when their
identity metadata contains solicitation, URL, domain, or encoded-HTML scam
signals.
