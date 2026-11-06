# Oath website

Production: https://oathwallet.org

Canonical source: `Website/` in the public [OathWallet/oath-wallet repository](https://github.com/OathWallet/oath-wallet/tree/main/Website).

Website, help, articles, public service implementations and deployment workflows are maintained together.
See [deployment instructions](../Distribution/README.md). The npm `private` flag only prevents accidental npm-package publication; this source is public.
Public support address: `care@oathwallet.org`.

## Publish articles from GitHub

Add a folder in [Website/content/articles](content/articles/README.md) and merge its pull request into `main`. GitHub builds, checks and deploys the Articles site to Cloudflare automatically.

## WalletConnect mobile links

WalletGuide bases are `https://oathwallet.org` and `oathwallet://`.
The SDK appends `/wc?uri=…`; the Apple association is served as JSON without
redirection at `/.well-known/apple-app-site-association` and
`/apple-app-site-association`. It is restricted to `/wc` and `/wc/` for
the Oath Wallet application identifier. Keep it aligned with the signed app.
`src/wallet-links.js` handles this before site analytics/newsletter injection.
Never add analytics, arbitrary redirects or request logging to this entry point:
the URI can contain a pairing secret. The fallback's script clears the browser
query and forwards the URI only after the visitor taps Open Oath Wallet.
Run `node --test tests/wallet-links.test.mjs tests/hsts.test.mjs` after changes.
The native app must include its URL scheme and Associated Domains entitlement;
deploying the website alone does not upgrade existing app installations.

## Hosting

Cloudflare Worker `oath-website` serves `public/` with Workers Static Assets.
Its custom domains are `oathwallet.org` and `www.oathwallet.org`; `www` and HTTP
redirect to HTTPS on the apex domain. This is independent of the app's notification Worker.

Cloudflare manages custom-domain DNS records and TLS certificates. Only files inside
`public/` are deployed as public assets. `src/mcp.js` implements the read-only discovery endpoint
on Cloudflare at `/mcp`.

All HTTPS responses, including redirects, errors and `/mcp`, carry
`Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`.
HTTP requests permanently redirect with status 301 to HTTPS on the same host before
the canonical www-to-apex redirect. All present and future subdomains must support HTTPS.
The preload directive does not by itself confirm inclusion in browser preload lists.
Public leadership information is maintained on `/press#leadership` and its text/data mirrors.
Cloudflare's zone-level minimum TLS version is 1.2, with TLS 1.3 enabled
(SSL/TLS → Edge Certificates). This setting is managed separately from the Worker.

## Develop and deploy

Use Node.js and the Cloudflare account that owns `oathwallet.org`.

```sh
npm ci
npm run dev -- --ip 127.0.0.1 --port 8793 --local-upstream 127.0.0.1
```

The explicit local upstream keeps Wrangler from using the production route hostname
for local HTTP requests, which would correctly trigger the site's HTTPS redirect.

In a separate terminal:

```sh
npm run check
npm test
npm run deploy
npm run check -- https://oathwallet.org ../Reports/oath-website-deployment-2026-09-23/live
```

Browser checks use installed Google Chrome through Playwright. The project npm cache
is in `/tmp/oath-website-npm-cache` because this machine's default npm cache path is a file.

The Help Center shares the main site's canonical `Oath Header.dc.html` and
`Oath Footer.dc.html` designs. `npm run build:help-chrome` generates server-rendered
markup and external CSS from those components, preserving their geometry while
using light palettes and the light-background logo for the header, mobile menu,
and footer. This also runs before deployment.
Do not edit `src/help/site-chrome.js` or `public/help/site-chrome.css` directly.
The small menu controller is in `public/help/help.js`; it preserves the Help
Center's strict content policy without a browser-side template compiler.
Run `node --test tests/help-chrome*.test.mjs tests/help.test.mjs` after changes.

### Help Center link previews

Every Help Center HTML route uses the same global social image:
`https://help.oathwallet.org/help/assets/oath-help-center-v1.png` (1200 × 630 PNG).
The shared shell in `src/help/render.js` emits Open Graph image metadata and
`summary_large_image` Twitter/X metadata in the initial response; crawlers do not
need JavaScript. Guide titles and descriptions remain specific to the linked page.
The image is under `/help/`, which the Help Center serves through its static asset
binding, and is public to crawlers. No per-guide artwork is required.

If replacing the image, use a new versioned filename and update the shared constant
and cache header together. Social platforms cache previews independently; deployment
does not guarantee that a card on an existing post refreshes immediately.
Run `node --test tests/help-social-preview.test.mjs tests/help.test.mjs` before
deployment. `node scripts/check-help-social-preview.mjs` verifies every live sitemap
URL and the actual image response using crawler user agents.

## Export compatibility

- Keep the supplied `Oath … .dc.html` component names: pages fetch them by name.
- Source templates are enclosed in `<template data-oath-template>` so browsers do not
  request unresolved image URLs or parse unresolved SVG coordinates. The two matching
  template lookups in `support.js` support this inert markup. Rendered artwork is unchanged.
- React 18.3.1, React DOM 18.3.1 and Babel 7.29.0 are bundled under `assets/vendor`.
  Their hashes were verified against the export's SHA-384 integrity values.
- Google Fonts remain external, with the supplied system-font fallbacks.
- The supplied social images, JSON-LD, markdown mirrors, robots, sitemap and MCP
  discovery files are retained. The not-found page is a real branded HTTP 404.
- `/mcp` is stateless, supports Streamable HTTP versions 2025-06-18 and 2025-03-26,
  and exposes the supplied eight tools, nine resources and one prompt. It has no
  wallet access, data storage or email-sending capability.
- To publish or update an editorial, follow the [GitHub article publishing guide](content/articles/README.md).

The support form opens an email draft in the visitor's mail app. Hosting the website
does not create the `care@oathwallet.org` mailbox; mail receiving must be configured
separately with the domain's email provider.

All eight public pages use extensionless URLs. Legacy `.html` links redirect permanently to the clean route; component templates remain internal static files. Version 3 adds the Security page.

## Google Search and canonical URLs

The verified Search Console domain property is `sc-domain:oathwallet.org`; it
covers the main site, `articles.oathwallet.org` and `help.oathwallet.org`. Each host
has its own sitemap, referenced in robots.txt and submitted in Search Console.
The main sitemap is an index with separate core-page and bounded token sitemaps. Legacy support
URLs permanently redirect to the Help Center, and legacy article URLs permanently
redirect to their matching article, preserving the path and query parameters.

`npm run build:seo` maintains homepage answers from
`content/self-custody-questions.json`, the canonical main sitemap, article
breadcrumbs and the archive's WebSite identity. `build:search` then renders the
same useful content in the initial HTML. Both run before deployment. Keep actual
editorial modification dates; do not replace dates with the deployment time.
Article and Help Center sitemaps derive their dates from published content.
The readable-page build defers `support.js` and preloads its two required local
React dependencies with matching integrity/CORS settings, keeping the existing
interactive design while removing a parser-blocking enhancement script.

The homepage retains a dated, attributed App Store rating for readers. Imported
App Store reviews and ratings are not included in Google's review markup.
`MobileApplication` still describes the actual app and its public release.
Keep the visible snapshot and its source date honest when refreshing it.

`content/priority-guidance.json` supplies practical questions, original versioned
screenshots and related links for priority network, token and feature pages.
`build:decisions` builds `/networks/fees` from the existing network guidance and
`/networks/choose-token-network` from the accepted token snapshot and identity
ledger. All entries are rendered before JavaScript; filters are progressive
controls, not separate indexable URLs. No live provider or wallet connection is
used. Catalog refreshes regenerate these pages through the normal build.

`content/articles/oath-wallet-release-history` describes recorded distribution
separately from earlier source releases. Update it only from release evidence.
The About page explains editorial attribution, review limits and corrections.

For a private aggregate landing-page report, use `scripts/seo-organic-report.sql`
through an already authorized database connection. It is a read-only query of
existing data and needs no migration or new tracking. It reports sessions with
App Store clicks, not installations; referrer attribution can be incomplete and
does not establish whether a search referral was paid or organic. Compare its
28-day reporting window with Search Console's available dates. Do not publish
raw visitor rows or private dashboard results.

After deployment run:

```sh
python3 scripts/audit-search.py /tmp/oath-search-audit.json
node --test tests/seo-migration.test.mjs tests/search.test.mjs tests/articles.test.mjs tests/help.test.mjs
```

The read-only audit crawls all three sitemaps, checks canonical URLs, titles,
descriptions, languages, JSON-LD, reciprocal hreflang, and first-party links and
images. It requires Python 3 and curl. Inspect live Google URL data separately:
a passing technical audit and successful sitemap submission do not guarantee
indexing or ranking. IndexNow's postdeploy acknowledgement is for participating
engines; it is not a Google indexing request. General web pages must not use
Google's restricted Indexing API as a substitute for Search Console.

The October 20 audit and deployment evidence is in `Reports/seo-2026-10-20/`.

## ChatGPT search crawler access

All three public hosts explicitly allow `OAI-SearchBot` (search discovery) and
`ChatGPT-User` (user-requested retrieval). Each serves its own sitemap; the apex
also advertises the other two. Public content is rendered before JavaScript.
The main robots file is `public/robots.txt`; article/help rules share
`src/search-crawlers.js`. Keep both covered by `tests/search-crawlers.test.mjs`.
Each host's `/llms.txt` serves a generated guide to its published documents.

`GPTBot` is a separate training crawler. This change preserves its existing
permission; allowing search does not require enabling training. `llms.txt` is
an optional reading guide, not a required indexing or recommendation mechanism.
Robots rules are public preferences, not authorization. Keep authentication,
newsletter administration protection, and wallet-link `noindex` unchanged.

Cloudflare checks are separate from robots.txt. Inspect Security Events and AI
Crawl Control for verified `OAI-SearchBot` requests on the public hosts. If a rule
blocks them, adjust only that rule for verified search traffic. Do not exempt
requests merely because their User-Agent says OAI-SearchBot, disable the WAF
globally, or permit access to protected administration/API routes. Use OpenAI's
current published IP ranges if an IP rule is necessary; never paste a permanent
snapshot into application code. The separately configured default-client exception is documented below;
Worker deployments do not change zone security settings.

Reference: https://developers.openai.com/api/docs/bots

After deployment run `python3 scripts/check-search-crawlers.py`. It verifies all
sitemap URLs against robots rules and samples three pages per host using search,
user-retrieval and browser User-Agents (90 page requests across Google, Bing,
Apple, OpenAI, Anthropic, Perplexity and a browser). It checks HTTP status,
content type, challenges, indexability and readable HTML. Requests come from the
runner, not OpenAI's IPs, so this proves public access only. Confirm verified-bot
access separately in Cloudflare logs. Neither check guarantees indexing, a
citation, a recommendation, or ranking. Run `audit-search.py` for the full site.

`scripts/seo-organic-report.sql` groups existing hostname-only referrals by
search engine and AI service, with aggregate outbound App Store clicks. It adds
no tracking fields. Missing referrers remain unattributed; Google and Bing AI
answers cannot be separated from ordinary search by these referrers. Clicks
are not installs, and referrals do not count all AI citations or recommendations.

The attributed US App Store rating snapshot lives in
`public/oath-data.json` (`facts.app_store_rating`). Update its value, count,
check date and official source together after verifying Apple. `build:seo`
uses that snapshot for the visible homepage and Markdown; it does not fetch
Apple during deployment or add imported review/rating structured data.
Homepage and features product metadata share the same released facts. Keep
historical guide versions and review dates intact when updating those facts.

## Current release documentation

`content/release-evidence.json` pins the security page's source revision and exact
excerpts. Verify them with `python3 scripts/verify-source-excerpts.py /path/to/oath-wallet`.
`tests/current-release.test.mjs` checks the code viewer, guide mirrors, feeds and
screenshot provenance. Refresh these together when updating the reviewed release.
The App Store schema in `scripts/build-seo.mjs` identifies the publicly available
version, which may differ from a newer submitted source release. Do not equate
submission, approval, internal release checks and an independent audit.

Help pages use only `src/help/content.json` in Git. The deployed worker never fetches help text from a separate CMS.
Screenshots retain their capture version independently of the text's app version.

## Unified public documentation interfaces

`src/agent-content.js` derives a 191-document catalog from the published core
Markdown, article routes/metadata, and Help Center JSON used by the HTML renderer.
Every catalog entry has a canonical URL and a Markdown URL. `GET`/`HEAD` with
`Accept: text/markdown` serves the same document; HTML advertises the alternate
through a Link header. Both negotiated formats use `Vary: Accept`. Wildcard or
HTML-preferred requests retain HTML. No User-Agent determines document content.

All three hosts expose `/llms.txt` and `/agent-documents.json`. The build generates
the main guide, complete text, index, and MCP card. Help text, steps, related links,
app versions and authored dates are taken directly from the visible help source.
Editorial history is explicitly labeled; source evidence retains its pinned
version and review date, and does not assert an independent audit or current
App Store availability. Never update a review date merely because a build ran.

MCP `search_help` searches all help instructions; `list_documents`, `read_document`
and resources expose the same catalog. Reading accepts exact catalog URLs only,
never arbitrary network destinations. Existing origin checks, body bounds,
read-only behavior and private-route isolation remain in force.

Run `npm run predeploy && npm run test:unit` before publication. After deployment,
run `node scripts/check-agent-access.mjs`: it checks every catalog document with
bounded concurrency, then exercises recovery search, network instructions and
App Store link retrieval. This supplements `check-search-crawlers.py`.

### Cloudflare default-client compatibility

On 2026-10-31, a default Python User-Agent received Cloudflare error 1010 while
browser and search clients received 200 on the same public document. Browser
Integrity Check remains enabled globally. A configuration rule named
“Public documentation — non-browser readers” turns off only that browser-specific
header heuristic for GET/HEAD on the explicitly listed main-site documents,
Help Center article/collection routes, and public Articles host paths (excluding
admin, api and underscore-prefixed paths). It does not bypass WAF, rate limiting,
DDoS, authentication or MCP origin validation, and grants no private access.
Write requests and other hosts are outside this exception. Automated clients
should identify themselves truthfully; never impersonate a verified crawler to
obtain privileges. Cloudflare zone configuration is separate from Worker deploys.

On 2026-11-05 the same rule was extended to the public `/release-status.json`
endpoint on the main and Help Center hosts, the main-site `/bug-bounty` and
`/bug-bounty.md` pages, and public `/networks/` documents. The method and host
restrictions and all other security controls remain unchanged. The deployment
check now tests every Markdown document and release metadata with a default
Python client User-Agent, in addition to the identified documentation checker.

On 2026-11-06 the new feature pages exposed the same default-client restriction.
The existing main-site exact-path set was extended with these six public paths:
`/features/revoke-token-approvals`, `/features/icloud-wallet-backup`,
`/features/walletconnect`, and their `.md` representations. The rule still applies
only to GET/HEAD on its listed public hosts and paths; no other security setting
was changed. New feature routes must be checked with both identified and default
clients before declaring a deployment complete.

### Shared website logo

Edit `content/brand/oath-logo.svg` to update Oath's logo. `npm run build:brand`
(runs first in `predeploy`) generates the website logo, compatibility aliases,
favicon SVG/PNG/ICO, touch icon, install icons and press app-icon downloads.
Header, footer, homepage, splash, Help Center and press previews use this source.
The source hash versions logo URLs so each change also refreshes browser caches.
Do not edit generated logo copies or introduce separate light/dark logo designs.

## Bing and IndexNow

The GitHub deployment notifies IndexNow only after production checks pass.
It includes the main catalog, Help Center and Articles, with separate batches
of at most 10,000 URLs per host. Public ownership files are served on each host.
Successful content hashes are cached between production runs; changed and
removed URLs are submitted, while unchanged pages are skipped. Cache eviction
causes a complete resubmission, not missing coverage. Failed submissions leave
the previous successful state intact. Use `npm run notify:search -- --dry-run`
to review the inventory without submitting. Submit each host's sitemap in Bing
Webmaster Tools separately; accepted notifications do not establish indexing.
