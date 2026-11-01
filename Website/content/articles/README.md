# Publish an article from GitHub

1. Open [the article folders](https://github.com/devdasx/oath-wallet/tree/main/Website/content/articles) and create a branch. Use **Add file → Create new file** to create a folder such as `reading-a-token-approval/` with an `article.md` file. The folder name becomes the permanent URL on `articles.oathwallet.org`. Use lowercase letters, digits and hyphens.
2. Add `metadata.json` and upload your cover and any charts to **the same folder on the same branch**. The [Binance editorial](binance-withdrawals-who-signed/) is a complete example.
3. Open a pull request. Check the article text, sources and images in GitHub. When **Website checks** passes, merge into `main`. The [Deploy website workflow](https://github.com/devdasx/oath-wallet/actions/workflows/deploy-website.yml) automatically builds the HTML, Markdown, archive, feeds, sitemap and agent listings, deploys to Cloudflare, and checks production. The workflow uses the existing website deployment credentials.
4. Open `https://articles.oathwallet.org/<folder-name>` after the workflow succeeds. To correct it later, edit the same source files and advance `updated_at`. Keep the folder name and publication date stable.

## Metadata

```json
{
  "title": "Reading a Token Approval",
  "excerpt": "The short description shown in the archive and link preview.",
  "category": "Security",
  "published_at": "2026-11-01T12:00:00Z",
  "cover": "cover.png",
  "cover_alt": "Describe the cover for someone who cannot see it."
}
```

Dates use UTC and include seconds. Optional fields are `updated_at` and an HTTPS `original_url` for a cross-post. Publication happens on merge, including for future dates. The current authoring format publishes English articles.

The body starts with the first paragraph. The page already displays the title and excerpt. Separate paragraphs with blank lines. Use `## Heading`, ordinary Markdown links, bold text, lists, and a standalone line such as `![What the chart shows](chart.png)` with a blank line on either side. Use lowercase image filenames with PNG, JPG, JPEG, WebP or AVIF extensions. Upload only media you intend to make public. Raw HTML is displayed as text.

Commit only the article folder for content changes. GitHub generates the public files for each deployment. For an optional local preview, run `npm ci`, `npm run predeploy`, and `npm run test:unit` in `Website/`.
