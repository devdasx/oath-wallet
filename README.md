# Oath Wallet 5.0.3 prerelease

A native multichain wallet for iPhone and iPad.

**Prerelease: 5.0.3 (105).** This source preview improves scanner review, network recovery, history synchronization and restored-wallet compatibility. The Apple-approved release remains **5.0.2 (104)**. Build 105 has not been uploaded to App Store Connect.

[Published security review and remaining scope](https://github.com/OathWallet/oath-wallet-security-review) · [Current release metadata](https://oathwallet.org/release-status.json)

[Prerelease notes](releases/5.0.3.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- Scanned addresses show their validated networks and logos, with clearer review actions and left-to-right address presentation.
- EVM send quotes can recover from a stale provider using a fresh, chain-verified fallback; broadcast retry rules remain unchanged.
- Story uses its dedicated RPC and explorer history path. Celo history uses smaller pages and individual receipt checks.
- NEAR history handles repeated indexed transaction versions without double-counting fees, and respects bounded rate-limit retry delays.
- XRP recovers an advancing recent-history window; THORChain refreshes finish cancelling earlier history work before starting a new generation.
- Restored wallets retain legacy passphrase metadata even when their passphrase is empty. Existing encrypted wallet formats remain readable.
- Retains the Solana WalletConnect delegate-approval review fix, including explicit allowance and unlimited-approval warnings.
- Improves optional token artwork, native status-bar handling and expected authentication-error classification.

Cronos infrastructure is included for compatibility testing but remains disabled in the app. It is not advertised as an enabled network.

## Public source boundaries

This public repository includes the app, bundled assets, local packages, patched
Reown dependency, tests, and the complete [website, Help Center and articles](Website/README.md).
Website service implementations and [deployment workflows](Distribution/README.md) are also public.
Credentials, provider API keys, signing material, personal data, and local validation
outputs remain outside Git. Website services are separate from the self-custodial iOS app. Remote recovery-phrase collection and its upload integration
are absent. Recovery input stays local; signing happens on the device.

Diagnostics retain the shared privacy filter and bounded local outbox. This public
build has no diagnostic upload transport or operator endpoint. Optional encrypted
iCloud backup is separate from diagnostics and requires your own Apple capability
configuration. Never put real wallet material in tests, issues, or support reports.

## Release verification

The [5.0.3 (105) prerelease](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.3-build105) identifies the source and build settings for this preview. Its [verification record](releases/5.0.3.md) lists the checks, exclusions and remaining runtime limitations. This is a GitHub prerelease only; no build 105 upload or review submission was performed.

The [5.0.2 (104) release record](releases/5.0.2.md) retains its Apple approval status and original validation evidence.

The [5.0.0 (102) delivery record](releases/5.0.0.md) documents the earlier build delivered to Apple.

Source review, secret scanning, compilation and focused tests are performed during
release preparation. These are maintainer-directed checks, not an independent
security audit or a reproducible comparison of Apple's redistributed binary.

## Build

Use Xcode 27 and Swift 6. The app deployment target is iOS 17; individual visual
features use availability checks for newer system versions.

```sh
git clone https://github.com/OathWallet/oath-wallet.git
cd oath-wallet
sh Tools/PreparePublicBuild.sh
open OathAtmosphere.xcodeproj
```

Select the **OathAtmosphere** scheme, which builds **Oath Wallet**. Dependencies are
pinned by package manifests and `Package.resolved`. The checked-in project can be
regenerated with XcodeGen using `project.yml`.

The preparation script only creates an empty, ignored local provider configuration.
No API key is needed to compile. Network-backed features and WalletConnect require
your own provider configuration; see [PublicBuild.md](Documentation/PublicBuild.md).
Device signing and iCloud require your own Apple development team.

Compile without launching a simulator or installing on a device:

```sh
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/oath-public-build CODE_SIGNING_ALLOWED=NO build
```

## Validation

```sh
python3 Tools/ValidatePublicRelease.py --scan
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
python3 Tools/CheckMultiWallet.py --lifecycle
```

Secret-scanner exceptions are restricted to reviewed public fixtures and syntax
false positives. Their file hashes are checked by the release validator; changes
require renewed review. Live network tests are opt-in. Simulator, device, and
App Store results must be reported separately from source and host tests.

For security issues, use [private vulnerability reporting](https://github.com/OathWallet/oath-wallet/security/advisories/new).
See the bundled third-party notices and dependency licenses for attribution.

## Reproducible security review

A [maintainer-commissioned, Codex-led review](https://github.com/OathWallet/oath-wallet-security-review)
now tracks the [5.0.2 (104) release](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.2-build104).
Earlier audit results retain their original tested commits; the current target and remaining work are recorded in the review repository.
It publishes its exact source targets, findings, tests, and outstanding coverage.
The review is **in progress**, is not independent certification, and does not
establish equivalence with Apple's distributed binary. Later changes do not
automatically inherit its conclusions.
