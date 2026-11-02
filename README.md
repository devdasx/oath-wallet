# Oath Wallet 5.0.0

A native multichain wallet for iPhone and iPad.

This repository contains **Oath Wallet 5.0.0, build 102**. The application bundle identifier is `com.aperture.wallet`.

[Release notes](releases/5.0.0.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- Faster Bitcoin history loading and more reliable Litecoin payment destinations.
- Contract-level token approval reviews and individual results for batch revocations.
- WalletConnect gives specific recovery steps for expired QR codes, offline connections and unsupported requests.
- Improved compatibility with historical wallet records and stronger verification of encrypted backups.

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

The [5.0.0 (102) release](https://github.com/devdasx/oath-wallet/releases/tag/v5.0.0) identifies the application source used by GitHub Actions. Its delivery receipt records the uploaded IPA checksum and the build identifier returned by Apple. See the [release record](releases/5.0.0.md) for the verification steps.

Source review, secret scanning, compilation and focused tests are performed during
release preparation. These are maintainer-directed checks, not an independent
security audit or a reproducible comparison of Apple's redistributed binary.

## Build

Use Xcode 27 and Swift 6. The app deployment target is iOS 17; individual visual
features use availability checks for newer system versions.

```sh
git clone https://github.com/devdasx/oath-wallet.git
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

For security issues, use [private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new).
See the bundled third-party notices and dependency licenses for attribution.

## Reproducible security review

A [maintainer-commissioned, Codex-led review](https://github.com/devdasx/oath-wallet-security-review)
starts at 4.1.15 (100), commit `c7cdbde5e9f136b595500e92fbc904b107dcd8ee`.
It publishes its exact source targets, findings, tests, and outstanding coverage.
The review is **in progress**, is not independent certification, and does not
establish equivalence with Apple's distributed binary. Later changes do not
automatically inherit its conclusions.
