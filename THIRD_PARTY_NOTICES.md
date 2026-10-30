# Third-party notices

The repository license applies to Oath-owned code. Bundled and fetched dependencies
retain their own licenses; this file does not relicense them.

## Reown / WalletConnect

The patched source is included at `Vendor/Reown`. Its WalletConnect Community
License is retained at [Vendor/Reown/LICENSE](Vendor/Reown/LICENSE). The AppKit
license is retained at
[Vendor/Reown/Sources/ReownAppKit/LICENSE](Vendor/Reown/Sources/ReownAppKit/LICENSE).
The public copy includes local diagnostics integration and compatibility patches.

## Trust Wallet Core

The pinned binary dependency and checksum are declared in `Packages/WalletCore`.
The Apache 2.0 license is retained at
[Packages/WalletCore/LICENSE](Packages/WalletCore/LICENSE).

## IBM Plex Sans Arabic

Bundled fonts retain their SIL Open Font License at
[OathApp/Resources/Fonts/OFL.txt](OathApp/Resources/Fonts/OFL.txt).

## swift-secp256k1

The local wrapper uses `21-DOT-DEV/swift-secp256k1` for cryptographic operations.
Source: https://github.com/21-DOT-DEV/swift-secp256k1

MIT License

Copyright (c) 2026 Timechain Software Initiative, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Other fetched dependencies

Dependency manifests and the Xcode workspace's `Package.resolved` identify the
exact versions. Their upstream repositories retain their respective notices:

- GRDB: https://github.com/groue/GRDB.swift
- BDK Swift: https://github.com/bitcoindevkit/bdk-swift
- SwiftDraw: https://github.com/swhitty/SwiftDraw
- Swift DocC Plugin: https://github.com/apple/swift-docc-plugin
- WalletConnect QRCode: https://github.com/WalletConnect/QRCode
- Mobile Wallet SDK: https://github.com/MobileWalletProtocol/wallet-mobile-sdk
- Reown Yttrium: https://github.com/reown-com/yttrium

Network, token, and third-party application names and artwork belong to their
respective owners and identify supported integrations; their inclusion does not
imply endorsement.
