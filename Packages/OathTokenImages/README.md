# Token artwork

`OathTokenLogo` is the app's shared entry point for remote token logos. Use it in
new surfaces rather than `AsyncImage` or a separate download. Native network logos
remain original-color bundled assets and work offline immediately.

The package has two layers:

- `OathArtworkSource`: Foundation-only URI normalization shared by provider
  metadata decoders. Supports HTTPS, upgraded HTTP, IPFS, Arweave, and inline
  image data. There is no chain-specific CDN allowlist. Complete URI hashes
  identify images, never ticker symbols.
- `OathTokenImages`: bounded anonymous downloads, ImageIO raster decoding, and
  native SwiftDraw SVG rendering. SVG stays vector; raster dimensions and
  original downloaded bytes are preserved. No web view or private image API.

CoinGecko large images are preferred over small/thumb URLs. TonAPI's signed
imgproxy images retain their signed URL as a fallback after trying the encoded
original source. Views may supply an additional stored metadata URL if richer
market information no longer works.

Memory caching is limited to 48 MiB / 128 entries. The original bytes and fetch
date persist atomically in `Caches/OathTokenArtwork-v1`, with a 128 MiB disk
budget. Saved images appear immediately; seven-day-old entries refresh while
remaining available offline. Failed downloads do not replace valid artwork and
are retried after a short cooldown. Concurrent rows share requests, with at most
six active downloads. View cancellation does not abort downloads used by others.

Images are untrusted data: requests have no cookies or credentials; redirects
are checked; responses, dimensions, SVG complexity, and expansion are bounded.
Executable SVG, external references, entities, and recursive drawings are
rejected. A missing or invalid upstream logo uses the app's initials placeholder;
artwork is never inferred from a ticker or used as a verification signal.

## Host-only validation

```sh
swift test --package-path Packages/OathTokenImages --scratch-path /tmp/oath-artwork-spm --build-system native
OATH_LIVE_ARTWORK=1 swift test --package-path Packages/OathTokenImages --scratch-path /tmp/oath-artwork-spm --build-system native
```

The optional live test downloads only public artwork listed in
`Tests/OathTokenImagesTests/Fixtures/live-artwork.json`. No RPC key, wallet address,
simulator, or physical device is needed. Source fixtures include Panora's USD1
PNG and USDC SVG; their marks belong to the respective projects. Tests also draw
the real SVG into a host CoreGraphics bitmap to verify visible original colors.

Provider decoding tests live in `OathAnkr/ArtworkMetadataTests`; persisted artwork
repair tests live in `OathDatabase/ArtworkPersistenceTests`; large-image preference
is covered by `OathMarketData/MarketDataTests`.

## Token identity resolution

`TokenArtworkResolver` wraps the byte cache with a bounded public-token identity
index (network + canonical reference + decimals). Search, Home, details, Receive,
Send, and history supply this identity to `OathTokenLogo`. EVM references are
case-insensitive; other networks retain their exact reference, including Move
module names and base58 mints. Symbols never identify artwork.

When a stored/guessed URI is absent or broken, the resolver reads the same saved
metadata as asset details, then requests validated metadata if necessary. A
successful URI is shared with visible rows and retained across relaunches. Index
I/O and image decoding run on actors, not on the main actor. Metadata requests
coalesce, have a cooldown, and run at most three at once. The index holds at most
256 entries in memory and 512 files / 16 MiB on disk. It contains no wallet IDs,
wallet addresses, names, or signing material. Native coins use bundled logos.

A missing optional listing/logo retains the neutral initials. It never substitutes
another token's logo by symbol or stores a placeholder as a successful image.

Host regression tests exercise all 31 token-capable network identities, stale
source recovery, screen-to-screen updates, concurrency, and offline relaunch.
`Tools/CheckTokenArtworkLive.py` creates a read-only public token manifest. Set
`OATH_LIVE_TOKEN_MATRIX` to that manifest's absolute path to run the actual
production downloader, image decoder, resolver and offline cache against it.
Catalog HTTP failures must be reported separately from successful image checks.
