# Native bottom-search regression

This small simulator-only fixture compiles the production
`OathHomeBottomSearch.swift` and `OathTypography.swift` files. It has local sample
rows and minimal localization dependencies; it does not initialize a vault, send
network requests, or access a real wallet.

The test checks Wallet → Search → Close → History → Search → Close → Wallet →
Search, including filtering, the context-specific placeholder, keyboard
submission, bottom field placement with/without the keyboard, and absence of a
persistent field on browsing tabs. It also checks Search → asset → Home using
both native Back and the edge-swipe gesture, with the keyboard visible or
dismissed, then reopens search to check that the previous query was cleared.
The fixture mirrors Home's selection handoff and compiles the production search
presentation modifier; the full-app counterpart is
`OathWalletHomeUITests.testNativeHomeBarsAndAssetSearch`.

Asset selection closes the native search presentation and routes through Home's
navigation stack. These navigation events and typed queries are not diagnostic
failures and are not reported to the shared error outbox.

Use only when a concrete search-presentation uncertainty warrants a simulator,
per AGENTS.md. With a dedicated simulator ID already selected, run from the repo
root (never substitute a physical-device destination):

```sh
mkdir -p /tmp/oath-search-regression-project
OATH_SEARCH_SOURCE_ROOT="$PWD" xcodegen generate \
  --spec Tools/SearchTabRegression/project.yml \
  --project-root /tmp/oath-search-regression-project \
  --project /tmp/oath-search-regression-project
xcodebuild \
  -project /tmp/oath-search-regression-project/OathSearchTabRegression.xcodeproj \
  -scheme SearchFixture \
  -destination "platform=iOS Simulator,id=$OATH_SEARCH_SIMULATOR_ID" \
  -derivedDataPath /tmp/oath-search-regression-build \
  -parallel-testing-enabled NO test
```

The fixture validates native search presentation, not full-app performance or
on-device behavior. In the initial isolated observation, the former automatic
placement did not reproduce the user's intermittent top-field state. No claimed
speedup or device-freeze reproduction is derived from this fixture.
