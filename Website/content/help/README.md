# Oath Help Center

Canonical public content lives in `Website/src/help/content.json`. Edit its
`categories` and `articles` in Git, then push to `main`. The website workflow
validates and deploys every guide, collection, search page and sitemap together.
No database editor or separate content service is used for publishing.

Content fields are escaped plain text: preserve IDs, slugs, app routes, related
links and original screenshot provenance. Use actual editorial dates. Never put
user data or recovery material in a guide or screenshot.

Files in this `content/help/` directory are historical authoring inputs and SQL
patches retained as source history. Do not apply them to a database, rerun old
generators over the current content, or treat historical app routes as current.
The production bundle imports only `src/help/content.json`.

The screenshots under `public/help/assets/` are historical simulator captures
using public synthetic fixtures; they do not prove a completed real transaction
or cloud backup. Keep their version context when updating text.

Run `npm run predeploy && npm run test:unit` in `Website/` and verify changed live
guides after deployment. See `Distribution/README.md` for release and rollback.
