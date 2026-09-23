# Recovery phrase copy regression tests

This isolated simulator app compiles the three production recovery phrase
screens, their copy state/label, and `UniHaptic` directly. It uses deliberately
invalid synthetic words and a separate bundle identifier. It does not load the
wallet database, Keychain, or network services. Only unrelated presentation
dependencies are substituted in `FixturePresentationSupport.swift`.

The regression was reproduced with a real tap on a native `List` copy row:
the separate `.uniHaptic` tap gesture intercepted the button action. Moving
haptic feedback into the copy action made the same test pass without changing
the clipboard implementation. The production label changes without a
replacement transition and returns to its ready wording after two seconds.

## Coverage

Every case verifies an actual tap, the localized copied label, exact clipboard
contents and word order, repeated copying, the two-second automatic reset, and
resetting feedback when the displayed phrase changes:

- Quick wallet creation (12 synthetic words).
- Physical-entropy wallet creation (24 synthetic words).
- Recovery phrase display.
- Arabic localization.
- Accessibility Dynamic Type in dark appearance.
- Landscape layout with 24 synthetic words.

The scroll helper keeps the row clear of the native bottom action bar before
tapping. Automatic screenshots are disabled in the generated test scheme.
No test captures or reads screenshots.

## Run

From the repository root, with Xcode 26 and XcodeGen installed:

```sh
COPY_TEST_DIR=$(mktemp -d /tmp/aperture-recovery-copy.XXXXXX)
xcodegen generate --spec Scripts/RecoveryPhraseCopyUITests/project.yml --project "$COPY_TEST_DIR"
xcodebuild -project "$COPY_TEST_DIR/RecoveryPhraseCopyFixture.xcodeproj" \
  -scheme RecoveryPhraseCopyFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$COPY_TEST_DIR/DerivedData" \
  -parallel-testing-enabled NO test
```

Run the same command with an available iPad simulator destination to cover iPad.
Run destinations sequentially when reusing DerivedData. Never use the main
app's default DerivedData directory for these tests.
The fixture uses ad-hoc simulator signing; it needs no development certificate
and ensures repeat runs install the current test bundle.

These interaction tests verify copying, state changes, and the two-second
reset without relying on screenshots or pixel-level appearance.

## Verification

- iPhone 17 Pro, iOS 26.5: 6/6 UI tests passed.
- iPad Pro 11-inch (M5), iOS 26.5: 6/6 UI tests passed.
- Main Aperture Release simulator build passed in isolated DerivedData.
