OATH WEBSITE — upload guide

1. Upload EVERYTHING in this folder to your web root (e.g. public_html/) keeping the same structure:
   index.html, features.html, articles.html, support.html, press.html, terms.html, privacy.html,
   the five "Oath … .dc.html" component files (incl. Oath Splash Web.dc.html), support.js, oath-icons.js, favicon.svg,
   apple-touch-icon.png, og-image.png, robots.txt and the assets/ folder.
2. Do not rename the "Oath Splash Web.dc.html", "Oath Header.dc.html", "Oath Footer.dc.html", "Oath App Home.dc.html" and
   "Oath Legal Doc.dc.html" files — pages load them by name.
3. The site must be served over http(s) (it will not work opened directly from disk).
4. Edit the header or footer once in its .dc.html file and every page updates.

Pages
  /               Home
  /features.html  Features
  /articles.html  Articles (generated from website content)
  /support.html   Support — care@oathwallet.org
  /press.html     Press kit
  /terms.html     Terms of Service
  /privacy.html   Privacy Policy

The site loads fonts from Google Fonts and React from unpkg.com at runtime.


AI AGENTS & MCP
===============
Everything below assumes the site lives at https://oathwallet.org. If your domain is different,
search-and-replace "https://oathwallet.org" in all .html, .md, .txt, .json, .xml and mcp.php files.

Discovery files (plain static files — nothing to configure):
  /llms.txt                 Short guide for AI agents (llmstxt.org format)
  /llms-full.txt            Every page's full text in one file
  /index.md, /features.md, /support.md, /press.md, /articles.md, /terms.md, /privacy.md
                            Markdown mirrors of each page (linked from each page with rel="alternate")
  /oath-data.json           Facts, features and FAQ as structured JSON
  /robots.txt               Explicitly allows GPTBot, ClaudeBot, PerplexityBot, Google-Extended,
                            Applebot-Extended and 25+ other AI/search crawlers; points to the sitemap
  /sitemap.xml              All pages + markdown mirrors
  /.well-known/mcp.json     MCP server card (also at /.well-known/mcp/server-card.json)
  /.well-known/security.txt Security contact (RFC 9116)

Inside every HTML page:
  - schema.org JSON-LD (Organization, WebSite, MobileApplication, FAQPage on Support, ItemList on Features)
  - <noscript> full-text version, so crawlers that don't run JavaScript still read the page
  - canonical URL, Open Graph / X card tags, Apple Smart App Banner

MCP server (Model Context Protocol):
  Endpoint:   https://oathwallet.org/mcp   (POST, JSON-RPC 2.0, Streamable HTTP, stateless, read-only)
  File:       mcp.php — needs PHP 7.4+ (standard on most FTP hosting). .htaccess routes /mcp to it.
  Tools:      get_overview, list_features, get_feature, search_help, get_contact, get_download,
              get_policy, list_articles
  Resources:  llms.txt and every page's markdown
  Prompts:    explain_oath
  Test after upload:
    curl -s https://oathwallet.org/mcp -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  Add to an MCP client (e.g. Claude, Cursor):  { "type": "http", "url": "https://oathwallet.org/mcp" }

Publish new articles through GitHub as described in content/articles/README.md. The build updates the archive and discovery files.
If your host uses Nginx instead of Apache, add:  location = /mcp { rewrite ^ /mcp.php last; }


SHARING PREVIEWS & ICONS
========================
  favicon.ico / favicon.svg / favicon-32.png / favicon-16.png   browser tab icons (the Oath app icon)
  apple-touch-icon.png, icon-192.png, icon-512.png, site.webmanifest   home-screen / app icons
  og/*.png   1200×630 preview image for each page (home, features, support, press, articles, terms, privacy)
Every page has Open Graph + X (Twitter) "summary_large_image" tags, so links shared on X, Facebook,
LinkedIn, iMessage, Slack, Discord, WhatsApp and Telegram show the large Oath preview.
After uploading, refresh caches with https://www.linkedin.com/post-inspector/ or by re-sharing the link.
