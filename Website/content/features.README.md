# Feature product pages

`features.json` is the reviewed source for the three product pages under `/features/`.
`npm run build:features` generates complete HTML, equivalent Markdown and Features
hub links. The normal `npm run predeploy` runs it before search content, sitemaps,
shared navigation and documentation discovery.

Keep page slugs stable. Review capability claims against the approved release,
not unreleased main. Update the release identity, source file hashes and review
date together only after that review. `tests/feature-pages.test.mjs` compares
source bytes with the pinned Git objects and the distribution record.

Screenshots are unchanged existing Help Center captures. Keep their original
version, sample-data disclosure, dimensions and SHA-256 alongside the image.
Do not relabel an older screen as a current release or describe a sample as a
completed live transaction or upload. Capture provenance is documented in
`help/README.md`.

Add supported networks and guide slugs only when their existing destinations
are valid. HTML and Markdown, core sitemap, document discovery, redirects,
source/screenshot provenance and critical limits are checked by the unit suite.
The deployment verifier compares live feature HTML, Markdown, CSS and image
bytes with the publishing commit. Responsive, keyboard and no-JavaScript browser
checks must still be performed for layout changes.

Cloudflare's public-document compatibility rule is separate from Git deployment.
When adding a feature route, include its exact HTML and Markdown paths in the
existing main-site GET/HEAD path list, following `../README.md`. Do not expand
it to all requests or disable other security controls. The existing default-client
production check catches omissions; keep that check enabled.
