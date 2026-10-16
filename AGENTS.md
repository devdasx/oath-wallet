# Oath Wallet public source

Version 4.0.3, build 77. Use `OathAtmosphere.xcodeproj`, scheme
`OathAtmosphere`, sources `OathApp/` and `OathAtmosphere/`.
Do not change stored Keychain, container, backup, or migration identities.

Keep keys and recovery phrases local. Never add remote recovery-input capture,
operator-readable wallet backup, bundled credentials, private backend deployment
files, or personal wallet data. Optional backup must encrypt before leaving the
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
