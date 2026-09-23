# Oath Wallet source release

Display/product name: **Oath Wallet**. The Swift target/module remains `Aperture`,
the source directory is `EVMWallet/`, and the bundle ID is `com.aperture.wallet`.
Do not change shipped Keychain service names, backup identifiers, or migration names.

Use the checked-in `EVMWallet.xcodeproj`. Xcode 27 and iOS 26+ are required.
Select simulators by UUID. Use a separate DerivedData directory and capture build
logs, preserving the xcodebuild exit status. Tests use Swift Testing with hosted,
serialized UI suites. A simulator build alone does not validate wallet behavior.

Security requirements:
- Wallet secrets are local Keychain values; database rows contain opaque references.
- Private keys and recovery phrases must never reach HTTP, telemetry, diagnostics,
  feedback, or operator-controlled storage. Signing is local.
- Optional backup/paired-device transfer must encrypt before leaving the device.
- Credential entry disallows third-party keyboards and Writing Tools.
- The bundled token catalog has no authentication or upload operation.
- Never commit credentials, signing files, user wallet data, or user-provided phrases.
  Only documented public test vectors may appear in tests.
- Run `python3 Scripts/validate_source_release.py` and the documented secret scan.

Use theme tokens, native SwiftUI navigation and lists, shared button components,
and localization keys. Add new UI strings to all 57 `.lproj` folders and run
`Scripts/validate_infoplist_localizations.py`. Do not introduce live-mainnet test
calls into the default test suite. See `SECURITY.md` and `docs/AUDIT_SCOPE.md`.
