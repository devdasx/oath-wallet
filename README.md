# Oath Wallet 4.0.3

A native multichain wallet for iPhone and iPad.

This repository contains the **4.0.3 source release, build 77**. The new app
replaces the previous source layout with `OathApp`, `OathAtmosphere`, and local
Swift packages. The application bundle identifier remains `com.aperture.wallet`.

[Release notes](releases/4.0.3.md) · [Website](https://oathwallet.org) ·
[Security](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- A redesigned native interface, new app icons, and refined send and receive flows.
- Multichain asset discovery, token artwork, pricing, and transaction history.
- WalletConnect transaction review and network-aware signing integrations.
- Network-grouped permissions and batch access revocation.
- Multiple wallets, encrypted local storage, app locking, and Recently Deleted.
- Legacy-wallet upgrade handling and improved refresh and scrolling behavior.

Capabilities vary by network, asset, provider, and configuration. Listing a
capability does not claim that every network or transaction has been tested.

## Public source boundaries

This source distribution includes the app, bundled assets, local packages, patched
Reown dependency, and tests. It excludes private backend deployments, backend
credentials, provider API keys, signing material, personal data, and local
validation outputs. Remote recovery-phrase collection and its upload integration
are absent. Recovery input stays local; signing happens on the device.

Diagnostics retain the shared privacy filter and bounded local outbox. This public
build has no diagnostic upload transport or operator endpoint. Optional encrypted
iCloud backup is separate from diagnostics and requires your own Apple capability
configuration. Never put real wallet material in tests, issues, or support reports.

## App Store source correspondence

As of October 19, 2026, Oath's maintainers confirm that the App Store release
corresponds to the source published in this repository. This is a maintainer
statement about source correspondence; the public-source boundaries and
configuration requirements documented above and below still apply.

This statement is distinct from an independently reproduced, byte-for-byte
comparison of an App Store download. No new binary comparison, independent
reproducibility report, or security audit is supplied by this README update.
A successful source build, Apple approval, or GitHub's Verified signature badge
is not by itself proof of source-to-store equivalence. Archived release notes
retain the scope of the checks documented when those releases were published.

For an independently verifiable claim, look for the exact app version and build,
source commit, toolchain, compared artifacts, method, exclusions, and result.
Read the [Reproducible Builds definition](https://reproducible-builds.org/docs/definition/)
for the distinction between source availability and reproducible output.

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
