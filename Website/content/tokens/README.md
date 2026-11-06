# Released token catalog

The accepted snapshot is `source.json.gz`. It is extracted from the app revision in `content/release-evidence.json`, only when the matching distribution record says `READY_FOR_DISTRIBUTION`. Source bytes, revision, release, date, enabled networks and native-alias exclusions are recorded in the snapshot. The current raw seed has 32,136 entries; the released app removes CELO's native ERC-20 alias, leaving 32,135 token entries, 20,017 asset groups and 38 token-capable networks. Four native-only networks retain their existing guides.

`routes.json` is a permanent identity ledger. Its compact array format avoids mistaking public token IDs for credential settings. Never delete retired identities or reuse their paths. Network plus canonical contract/mint/issuer/reference is the identity. The provider asset ID groups networks; the symbol does not. USDT and USDC reserve readable aliases. A changed provider grouping fails the refresh and requires an explicit migration review.

## Build and refresh

- `npm run predeploy` builds from the last accepted snapshot, without contacting token providers. Generated data lives in ignored `public/token-data/{version}/` shards; the version includes the renderer, styles and shared navigation.
- `npm run refresh:tokens` reads the approved Git source, validates the snapshot and existing URL ledger, then builds and tests. Invalid snapshots never replace the source file. Commit the accepted snapshot, ledger, manifest and generated tracked website files together.
- The **Refresh released website catalog** GitHub workflow runs on explicit dispatch or changes to approved release evidence/distribution. It publishes a review branch, dispatches Website checks and attempts to open a PR. If repository policy prevents automatic PR creation, its run summary provides the comparison link; no permissions are expanded. After review and merge, the existing **Deploy website** workflow publishes. No periodic refresh or alternate hosting path is used.
- A catalog-source update in an unreleased app branch does not change the public website.

## Rendering and discovery

The Worker serves complete HTML and Markdown, using 256 bounded asset shards, 50-row directory pages and a server-only search index. Page caches are keyed by the complete catalog/template version. Cache failures fall back to the accepted static snapshot; provider outages do not affect page rendering. Search pages are noindex. Unfiltered pagination has self-canonicals and normal previous/next links. Single-network overview URLs redirect to their exact detail pages. Unknown and removed identities return 404; unavailable build assets return 503, never a successful empty page.

`/sitemap.xml` is an index. `sitemaps/pages.xml` contains core pages; token files contain at most 10,000 canonical URLs each. Help and Articles retain their own sitemaps. `/tokens/documents.json?page=N` exposes at most 100 documents and a next link. The existing agent index and MCP link to this directory, and `read_document` accepts valid catalog URLs. Markdown and JSON are not alternate indexed pages.

Catalog inclusion is discovery evidence, not issuer verification or tested sending. Unknown logos use a text monogram; unknown decimals are omitted. XRP Ledger's internal scale sentinel is not presented as token decimals. Network fee and capability notes come from the existing reviewed guides. USDT/USDC pages add network-specific guidance and issuer reference links without declaring every catalog deployment issuer-approved.

## Token artwork

`artwork.json.gz` is an accepted artwork-only snapshot tied to the released catalog revision and source hash. It combines the seed's explicit images, bundled app details (asset ID plus exact network reference), published CoinGecko/GlueX token lists and the app's GeckoTerminal batch fallback. Network and canonical contract/mint/issuer/reference determine every match; symbols never determine artwork. No provider names, decimals, verification flags or financial metadata enter the catalog through this process.

`npm run refresh:artwork` explicitly refreshes public metadata, records source hashes and per-network coverage, then builds and tests. Provider failures retain accepted matches; removed catalog identities are discarded. A complete failure never empties the existing snapshot. `refresh:tokens` also refreshes artwork after accepting a released catalog. Builds and deployments never query these metadata providers. Commit the snapshot, generated manifests and tracked pages together.

The offline build produces 256 compact metadata shards under ignored `public/token-artwork-data/{version}/`. Visitors request only the images on their page through `/token-artwork/{version}/{identity-hash}`. This route accepts known identities only, restricts upstream hosts and redirects, bounds downloads and concurrency, validates passive image formats, and isolates direct SVG visits with a restrictive content policy. Images are cached at the edge for 30 days; after seven days they can refresh in the background while the previous image remains available. Browser caching lasts one day. Failed cold requests return escaped initials with a 60-second retry cache. Missing metadata displays initials without making an image request. A browser image error also reveals the initials.

Coverage counts represent matched image metadata, not a claim that every external image URL was downloaded or remains available. Logos do not imply issuer verification or asset safety. The same component serves directory/search rows, overview and exact-token guides, network lists, featured tokens and the transfer tool. Dimensions are reserved to prevent layout shifts, decorative images have empty alternate text, and visible token names and network badges remain accessible. Token text and navigation work without JavaScript.

## Verification and publication

Run `npm run test:unit` for all existing tests and exhaustive catalog identity, route, sitemap, rendering and link checks. `TokenDiscoverySnapshotTests` also validates every shipping identity with the app's actual canonicalizers. Run the browser test with the local Worker:

```
npx wrangler dev --ip 127.0.0.1 --port 8794 --infer-origin-from-routes=false
node --test tests/tokens-browser.test.mjs
```

The browser test covers 320/390/1024/1440 widths, real assets, keyboard navigation, network search and a JavaScript-disabled flow. `npx wrangler deploy --dry-run` verifies packaging. Follow root publication requirements for secret scanning, diagnostics coverage, host tests and generic iOS compilation. Do not launch simulators or physical devices for this website task.

Production search audits traverse every sitemap, check robots access for every URL, and inspect all existing core/help/article pages plus bounded samples from every token network and page type. Exhaustive catalog validation is offline; production audit output states its scope. IndexNow notifications are batched at 10,000 URLs. Acknowledgement is not indexing confirmation.

After GitHub deployment, submit the sitemap index in Search Console, inspect priority and representative pages, and record indexing requests separately from confirmed index coverage. Google controls crawling and inclusion. Keep legitimate redirects, retired content and machine-format exclusions intact. Roll back an observed production regression by reverting the website change through GitHub and verifying the restored Deploy website run.
