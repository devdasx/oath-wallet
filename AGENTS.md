# Oath Wallet public source

Version 4.1.15, build 99. Use `OathAtmosphere.xcodeproj`, scheme
`OathAtmosphere`, sources `OathApp/` and `OathAtmosphere/`.
Do not change stored Keychain, container, backup, or migration identities.

Keep keys and recovery phrases local. Never add remote recovery-input capture,
operator-readable wallet backup, bundled credentials, or personal wallet data. Optional backup must encrypt before leaving the
device. Only documented public synthetic key material belongs in tests.

Changed features use `Packages/OathDiagnostics` at swallowed-failure boundaries.
Preserve filtering, bounds, cancellation behavior, and non-recursive reporting.
This public release uses its local outbox without an upload transport.

Default to source review, generic iOS compilation, and focused host tests. Do not
launch a simulator without a specific unresolved runtime concern or explicit
request. Do not use a physical device without new explicit user authorization.
Report builds, host tests, runtime checks, and live-network checks separately.

Before publication run `python3 Tools/ValidatePublicRelease.py`,
`gitleaks dir . --redact=100`, `python3 Tools/CheckDiagnosticsCoverage.py`, the
diagnostics host tests, and a generic iOS build. Review scanner exceptions by
content and preserve the exact file-hash checks. Never print secret values.

Website/ contains the public website, help, articles and website service source.
It is independent of the iOS target and must never be bundled into the app.
Website backend URLs are public configuration; credentials remain deployment secrets.

Describe this repository and its behavior directly. Do not reference other
projects or unpublished development implementations in public documentation,
release notes, tags, or commit messages.

Before publishing, review release notes, tag annotations, commit messages and
website copy for references to unpublished products or omitted implementation
variants. Describe the shipped behavior directly, and keep audit and build
verification claims limited to evidence actually obtained.

Recovery phrases, private keys and passphrases must use the sensitive clipboard
helper: device-only copying with a 60-second system pasteboard expiry. Public
addresses and transaction identifiers use the ordinary helper. Preserve this
boundary during feature updates and run `python3 Tools/CheckClipboard.py` when
changing copy behavior.
