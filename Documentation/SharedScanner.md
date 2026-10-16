# Shared scanner

Implemented on 2026-10-14. `OathScanner` in
`OathAtmosphere/Import/OathRecoveryScanner.swift` is the only scanner UI. Home,
Send recipient, contact address, recovery phrase import and private-key import
all present it. `Scanner/OathScannerCamera.swift` is the only capture session;
`Scanner/OathScanImage.swift` is the only photo QR decoder.

## Experience and routing

- Full-screen camera, dark vignette, rounded corner frame, neutral native
  toolbar controls and shared glass Photos / Paste / Flashlight controls.
- Camera permission, restricted/unavailable camera, interruption, invalid QR,
  no QR, multiple QR and payment review states stay inside this scanner.
- A Home address scan opens the existing Select Asset screen immediately. Its
  native coins and tokens are filtered by the scan's compatible networks; payment
  URIs also restrict the requested token/native coin. Selecting an asset applies
  the address, amount and memo together. The scanner has no network-choice step.
  Network-specific send/contact scans return to their selected network directly;
  mismatches and contact scans containing payment instructions remain blocked.
- Recovery phrases are validated locally against BIP-39 word lists and checksum.
  The preview masks the phrase. Import opens only after explicit approval, using
  the existing wallet import flow. Neither scanning nor connecting signs or
  broadcasts a transaction.
- Recipient, amount, token and memo are passed together to the send composer,
  which revalidates the selected asset and supported memo semantics. Unsupported
  payment instructions are rejected instead of silently discarded.
- Camera setup, capture start/stop and torch changes use a serial background
  queue. Photo QR recognition and payload classification run off the main actor.
  Generation checks discard cancelled/background results. Photos cleanup cannot
  clear a newer selection. Modal handoffs wait for the result sheet to dismiss.

## Scanner responsiveness (2026-10-14)

The source contained a UI-thread capture-graph stall path: each recognition
result removed the preview, whose `dismantleUIView` synchronously disconnected
its session while the capture queue stopped that same session. SwiftUI updates
and layout also repeatedly assigned the preview connection's rotation on the
UI thread. These operations can contend with AVFoundation's blocking lifecycle
work. No on-device hang trace was collected, so the reported 4–6 seconds is not
presented as a measured reproduction.

The preview now stays mounted for the scanner's lifetime, with an opaque privacy
cover when inactive or presenting a result. Its session/connection is created,
oriented once and disconnected on the capture queue; UIKit only mounts/sizes
the layer. Start/stop requests coalesce, obsolete requests are discarded, and
one QR batch is claimed per activation. Pausing immediately invalidates queued
callbacks even if AVFoundation is busy. Explicit retry still re-arms capture.
Continuous autofocus/exposure and the supported near-focus hint improve QR
acquisition without restricting detection to the drawn frame.

`OathScanRecognizer` is a shared actor separate from MainActor. It warms one
immutable dictionary task when the scanner opens. Addresses, scoped private-key
imports and WalletConnect do not wait for BIP-39 loading; phrases await that task
and still undergo all word-list/checksum validation and explicit import consent.
Cancelled requests cannot publish a late phrase result. Scan payloads/results
are not cached or logged. Focus failures use the existing diagnostics outbox;
duplicate frames, cancellation and input classification are expected control
flow, not errors.

Reference: [Muun's native metadata scanner](https://github.com/muun/falcon/blob/d6719c00f96d2ecbde2ab6588f95e54975ceea0e/falcon/app/falcon/Extension/ScanQRViewController%2BCamera.swift)
uses the first native QR metadata callback with a persistent preview and no
classification debounce. Oath keeps all blocking start/stop work off the UI
thread. Apple's [near-focus documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/autofocusrangerestriction-swift.enum/near)
specifically recommends this hint for machine-readable codes.

Host verification: `python3 Tools/CheckScanner.py --performance` passes 2,021
concurrency/lifecycle checks, including a deliberately blocked dictionary load,
responsive MainActor/address recognition, single-flight loading, cancellation,
duplicate frames, stale callbacks and retry. Measured parser p95 on this Mac:
Bitcoin 0.17 ms, Stellar 0.24 ms, EVM 0.21 ms and recovery phrase 0.07 ms.
Cold dictionary load was 28 ms; address recognition while its loader was
deliberately blocked took 0.26 ms. These are host classification measurements,
not camera acquisition or iPhone UI timings. Existing 6,383 scanner checks and
335 QR-image round trips pass, along with diagnostics coverage, diagnostics host
tests (45 executed, 2 skipped), and the generic iOS build. No simulator or
physical-device camera/visual checks were run.

## Address coverage

Tests require coverage of every case in the production chain catalog (34 at this
revision). EVM networks use address checksum validation; ambiguous addresses are
resolved by selecting an asset on its network. Bitcoin covers legacy, nested SegWit, native
SegWit and Taproot; Litecoin, Dogecoin and Bitcoin Cash use the existing send
script validators, including CashAddr and supported legacy formats.

Bare-address detection gives concrete address formats priority over NEAR's
permissive named-account grammar. A valid Bitcoin SegWit/Taproot, Litecoin
SegWit or Bitcoin Cash address must not acquire a NEAR option merely because
it contains lowercase letters and digits. Named NEAR accounts remain a fallback;
native implicit, Ethereum-like implicit and deterministic NEAR address formats
retain genuine overlaps. Explicit `near:` requests still use NEAR's full account
validator. This classification is offline expected validation, not a diagnostic
failure; it never looks up or logs scanned contents. Host regressions assert
complete candidate sets and decoded routing, including QR image roundtrips.

The 2026-10-14 address-routing regression run passed 6,383 host assertions and
335 actual CoreImage/Vision QR round trips across the 34-chain catalog. It covers
Bitcoin/NEAR false matches, genuine format overlap, direct Home-to-asset routing,
network-specific send/contact routing, native/token filtering and preservation of
payment amounts, contracts and memos. The wallet-link suite still passes 62
checks. Camera UI, navigation animations and physical-device scanning were not
exercised by these host tests.

Other formats include Solana, TRON, NEAR named/implicit accounts, Sui, Aptos,
TON/GRAM raw and friendly addresses, XRP classic and mainnet X-addresses, and
Stellar G-addresses and muxed M-addresses. Embedded tags/memos are retained and
conflicts are rejected. The scanner supports the payment URI subsets described
by `OathScanPayload.swift`; it does not claim to execute every optional field of
each URI specification.

## WalletConnect

Reown Swift 2.4.0 is pinned in `project.yml`. The supplied project ID is in the
ignored local `OathApp/Private/TokenRPC.plist`, under `WalletConnectProjectID`.
The existing local-config build step copies it into the app. No ID is stored in
this document or source files. The SDK uses the app's keychain access group;
SDK telemetry is disabled and its console loggers default to off.

Implemented: WC v2 QR validation, relay pairing, origin verification state,
explicit unverified-origin acknowledgement, wallet/account/network consent,
durable sessions, incoming message approval, fresh vault authentication with
passcode fallback, expiration handling, disconnect and safe rejection.

The EVM methods remain **personal_sign, eth_accounts, eth_requestAccounts and
eth_chainId**, with accountsChanged/chainChanged namespace support. EVM
transaction requests and typed-data signing are not implemented or advertised.

THORChain adds **cosmos:thorchain**, matching TCSwap's WalletConnect adapter,
and **cosmos_getAccounts, cosmos_signAmino, cosmos_signDirect**. The transaction
sign document must use the actual chain ID **thorchain-1**. Method permissions
are filtered per namespace, including optional methods. Required unsupported
chains/methods/events reject the proposal.

THORChain signing accepts one MsgSend (RUNE or bank token) or one native
MsgDeposit (THOR.RUNE/THOR.TCY). The review shows all amounts and denominations,
recipient or protocol deposit, the complete memo(s), and the real native fee.
The native fee is charged by THORNode even when the Cosmos fee list is empty.
Swap execution/output fees remain determined by the dApp/protocol. Unknown
messages, contract/synth/trade/secured asset deposits, multisig, fee grants,
extra signers and extension fields are rejected. This is not blanket Cosmos
or arbitrary-contract signing. Bank transfer amounts and account sequence,
fee, chain identity, halt state and balances are checked against THORNode;
they are checked again before authentication. A changed request must be
reissued by the dApp.

The approved signature and unchanged document return to the dApp, which owns
broadcasting. Oath does not submit a second payment or claim submission when
it only returned a signature. Each signature uses fresh vault authentication
with PIN fallback. Dismissal, expiry, disconnect and lock invalidate pending
preparation/authorization. No request payload is added to diagnostics.

The production swap.thorchain.org wallet picker still needs its maintainers
to register WalletConnect/Oath. App support cannot add a wallet to their site.
Existing sessions must reconnect to negotiate the new namespace.

Approval is bound to the selected wallet, account and chain. Signing rechecks
the pending request's topic/ID, wallet mapping, lock state and session expiration
after authorization. Locking, dismissal or an expired proposal cannot commit a
late approval; a session created during cancellation is disconnected. Older
requests without an explicit expiry get a bounded, persisted first-seen deadline.

## Privacy and diagnostics

Scanner failures use OathDiagnostics and the shared app-error outbox. Scan
contents, mnemonic words, private keys, WalletConnect URIs, signing messages and
signatures are never diagnostic context. A privacy regression checks complete
WC URI redaction, including pairing secrets. Payloads remain transient; the SDK
owns encrypted pairing key persistence. Neutral validation results, format
probes, cancellation, no QR, missing camera hardware and optional metadata are
expected states, not reported as per-frame/keystroke errors.

## WalletGuide mobile links (2026-10-14)

Dashboard values:

- Universal Link: `https://oathwallet.org`
- Deep Link: `oathwallet://`

WalletConnect appends `wc?uri=…` to the native base and `/wc?uri=…` to
the HTTPS base. Do not enter a generated pairing URI in the dashboard.
`OathWalletLink` accepts only this scheme/domain/route, validates the embedded
v2 pairing with the same parser as the scanner, and treats incomplete signing
wake URIs as a request to resume existing sessions, never as new pairings.
Cold scene options, warm UIKit callbacks and SwiftUI URL/user-activity delivery
feed one bounded, memory-only inbox. Duplicate deliveries coalesce. Requests wait
for unlock, foreground activation and the current modal to finish. The normal
connection consent and signing authorization remain mandatory. Queued requests
expire after five minutes; pairing expiry is rechecked before calling the SDK.
Untrusted malformed URLs are input validation, not diagnostic failures. Actual
configuration, pairing and transport failures use OathDiagnostics.

The `oathwallet` scheme is registered in Info.plist/project.yml. The signed app
requires `applinks:oathwallet.org` in its Associated Domains entitlement.
Cloudflare Worker `oath-website` serves the public Apple association at
`/.well-known/apple-app-site-association` (and its root alias), using application
identifier `C5T44SZNQX.com.aperture.wallet`, restricted to `/wc` and `/wc/`.
The browser fallback at `/wc` provides an explicit Open Oath Wallet button and an
App Store link. It never interpolates incoming data into HTML, loads no analytics
or third-party scripts, sends no referrers, uses `no-store`, and removes the query
from browser history. App metadata advertises these bases, with Link Mode off;
relay pairing remains the supported transport. Return to the originating app is
manual; QR-based connections do not redirect to untrusted app metadata.

Verification: 62 production link/inbox host checks; 428 scanner checks including
320 QR round trips; 42 website host tests; diagnostics coverage guard and 45
diagnostics tests (2 skipped, zero failures); unsigned and signed generic iOS
builds passed. The signed app's identifier, associated-domain entitlement and URL
scheme were inspected. Live HTTPS checks confirmed the association JSON and
private launch page return HTTP 200; Apple's association CDN also serves the
matching JSON. Production Worker version: `6603bccd-a42a-4012-b7b4-a4bd30a458ea`.
No simulator or physical device was used. App-opening handoff and on-device
Apple association caching are not verified. Existing installed/App Store builds
need an update containing this registration and entitlement before links work.

## Verification performed

All checks below ran on the host without a simulator or physical device:

| Check | Result |
| --- | --- |
| `python3 Tools/CheckScanner.py` | 428 assertions; 320 actual QR encode/PNG/decode round trips through the production image decoder; all 34 chains; 260 valid public BIP-39 vectors across 10 languages and all standard word counts |
| EIP-191 reference vectors (inside scanner check) | Empty, ASCII and Unicode messages match independent ethers digest/signature vectors |
| `python3 Tools/CheckMultiWallet.py --walletconnect` | 8 production vault authorization checks, including PIN failure, biometric fallback, account ownership and locking during authorization |
| `python3 Tools/CheckMultiWallet.py --authentication` | 103 biometric fallback and 158 security checks |
| OathDiagnostics host tests | 45 tests executed, 2 skipped, 0 failures |
| `python3 Tools/CheckDiagnosticsCoverage.py` | Pass; 402 observed catch sites, existing exclusions preserved |
| Generic iOS build, code signing disabled | Pass |
| `Tools/CheckWalletConnectRelay.cjs` | Live project/relay authentication, pairing, namespace approval, personal_sign verification and disconnect between isolated JS clients |

The relay smoke test uses pinned `@walletconnect/sign-client@2.23.4` and
`ethers@6.15.0`, memory-only peer storage and an intentionally public test key.
Provide the project ID through `OATH_WC_PROJECT_ID`; the script emits fixed
status text only. It never broadcasts transactions or reads app wallet data.

These results do **not** establish native camera performance, permission UI,
physical-device layout, or a live session through the iOS SDK and native app UI.
Those runtime checks were not performed. The broader unfiltered multi-wallet
host harness still contains unrelated fixed 31-network assertions; its full
suite is not reported as passing after the catalog grew to 34 networks.


### THORChain WalletConnect validation (2026-10-15)

- Generic iOS Debug build succeeded; no simulator/device launch.
- 10 deterministic package tests passed, including eight independently
  generated CosmJS Amino/Direct signature vectors, malformed/hidden authority
  rejection, and live-state review fixtures.
- Nine production vault authorization checks passed on the host (imported-key
  signer; synthetic biometric store; HD derivation not exercised).
- Six transactions confirmed on an isolated local THORNode: RUNE, custom bank
  token, and RESERVE protocol deposits, each via Amino and Direct signatures.
  Sender fee/debit and recipient credit were verified. No mainnet spending and
  no public testnet or cross-chain swap claim.
- Live WalletConnect relay: two isolated JS peers negotiated cosmos:thorchain,
  retrieved accounts, exchanged eight requests signed by the production Swift
  parser/signer, matched CosmJS responses, and disconnected. This does not test
  native iOS pairing/camera, mobile deep links, or the third-party site's UI.
- Scanner host suite passed 6,655 checks, including namespace method separation
  and 338 CoreImage/Vision QR round trips; no live camera.
- Diagnostics coverage passed; diagnostics host suite: 47 tests, two opt-in
  tests skipped, zero failures.

Reproduce with `Tools/GenerateThorchainWalletConnectVectors.cjs`,
`swift test --package-path Packages/OathAnkr --filter ThorchainWalletConnectTests`,
`python3 Tools/CheckMultiWallet.py --thorchain-walletconnect`, and
`Tools/CheckThorchainWalletConnectRelay.py`. Live local-node execution is opt-in
via OATH_THORCHAIN_SEND_FIXTURE; the fixture must belong to the isolated node
at localhost ports 28317/28657. Relay tests use only a public synthetic scalar
and the local project ID, never the user's wallets.
