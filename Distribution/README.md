# Deploy from the public repository

The canonical repository is `devdasx/oath-wallet`. The iOS app is at the root;
`Website/` contains the main site, Help Center, articles, newsletter interface,
assets, tests and website service implementations. Credentials are encrypted
GitHub Actions secrets, not source files. The website services are not included in the self-custodial app.

## Website updates

Edit `Website/` and push to `main`. **Deploy website** builds the shared navigation,
walkthroughs, SEO and readable pages, checks the site, then deploys the one Worker
serving all five configured hostnames. It verifies live pages and links afterward.
Help content comes exclusively from `Website/src/help/content.json`; a separate CMS cannot
override it. Use **Run workflow** to retry a failed deployment.

`production-website` needs `CLOUDFLARE_API_TOKEN`. Limit the token to the production
account, Workers Scripts edit, account settings read, and Workers Routes edit for
the `oathwallet.org` zone. It is an account-level Workers permission; it cannot be
described as access to only one Worker. Preserve the existing Worker secrets and
rate-limit bindings. DNS, TLS and mail-provider account settings stay in their
platforms; they are not changed by a website release.

## App releases

1. Update both project version/build settings, release notes, in-app version history
   and all affected localization strings. Put App Store release notes at
   `Distribution/metadata/<version>/<locale>/release_notes.txt`. Keep reviewer
   contact information and credentials out of this public directory.
2. Update the README/release record, security source excerpts, Help Center, articles
   and screenshots that actually changed. Preserve historical screenshot dates.
   Public App Store metadata must describe the publicly available version, even
   while a newer version is waiting for review. Do not invent an independent audit.
3. Commit and push, then create and push the immutable `v<version>` tag (or `v<version>-build<build>`
   for a replacement build of an already tagged version). Never move
   a released tag. The project version and build must match the workflow inputs.
4. Run **Release app and website** from `main`, entering version and build, plus the source tag for a replacement build.
   Leave **verify_only** on for checks, host tests and a generic iOS compilation.
   Turn it off to deploy the website and archive and upload the selected app build.

The app release uses a GitHub Xcode 27 runner and the checked source commit, supplies
provider configuration during signing, then uploads the exact build. It never submits a build for Apple review.
Apple performs build processing. Review submission and public release are separate
manual actions in App Store Connect. Website and Apple deployments are separate operations, not an atomic
transaction; inspect each job. A failed Apple job does not roll back a working site.

Existing Apple metadata and screenshots are retained. Committed release notes are
available for the later manual review submission. Missing Apple agreements, review information or encryption compliance
remain Apple-side prerequisites. The workflow does not guess encryption declarations.
Build 86 already exists in Apple and must not be uploaded again. Use verify-only
when checking `v4.1.3` / `86`.

`production-app-store` requires these encrypted secrets:

- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`: a dedicated Apple API key
  with authority to upload this app.
- `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_PASSWORD`: the selected
  Apple Distribution signing identity and its export password.
- `APPLE_PROVISIONING_PROFILE_BASE64`: an unexpired, manually managed App Store distribution profile
  for team `C5T44SZNQX`, bundle `com.aperture.wallet`, including the app capabilities.
- `OATH_PROVIDER_CONFIGURATION_BASE64`: the private provider plist described in
  `Documentation/PublicBuild.md`.

Never paste these values in a commit, issue or workflow log. Supply them through
GitHub's secret settings or `gh secret set` from local files/stdin. Signing uses a
temporary keychain. A temporary signing configuration selects the profile only for
the app target; dependency bundles receive no profile, and the tagged project is not edited.
Only sanitized source/build receipts are uploaded as workflow
artifacts; credentials, archives, IPAs and full build logs are excluded.
Check the receipt for `uploaded_and_processed` and the exact Apple build identifier.
Review is never submitted automatically. Rerunning must not reupload a used build number.

## Website backend source

`Website/services/supabase/` contains the newsletter and website analytics service
source and historical schema migrations. These services have runtime secrets in
the existing service account. Analytics also integrates with an existing personal
Vault notification/device-permission service; that external integration is not an
iOS app dependency. The SQL files document the existing schema, including those
relationships; they are not a standalone bootstrap for an empty database.

Do not run a blanket database push against the shared production project. Review
and apply only an explicitly selected schema migration when a change requires it.
The regular website deployment preserves the existing service deployment and its data.
After changing backend function code, run **Deploy website services** from `main`;
it deploys only these two functions. Its `production-website-services` environment
requires a separately configured `SUPABASE_ACCESS_TOKEN`. No schema or records are
modified by that workflow. Keep this optional deployment credential separate from
website and Apple access.
No subscriber list, analytics records, wallet records or operational secrets are
part of this public repository.

## Rollback and verification

For the website, revert the faulty source commit and let the workflow redeploy, or
use Cloudflare's retained previous Worker deployment while preparing the source fix.
App Store builds are immutable; fix an app defect with a new version/build.

Local checks: `npm ci && npm run predeploy && npm run test:unit` in `Website/`,
`python3 -m unittest discover -s Distribution/tests`,
`python3 Tools/ValidatePublicRelease.py --scan`, and the app checks in the root README.
These do not launch simulators, phones, or send test emails.

The workflow signs a public build receipt using GitHub artifact attestations.
Release notes link the receipt to its source commit, archive digest, Apple build
and workflow run. Apple may transform the distributed app; this is build
provenance, not an independent binary audit.
