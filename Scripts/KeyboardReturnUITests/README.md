# Keyboard Return regression tests

This isolated iOS app compiles the production `WalletTextInputDirection.swift`
and `WalletTextInputReturnKey.swift` files directly. It has a separate bundle ID
and does not load wallets, access wallet secrets, or contact providers.

The UI tests send actual Return keyboard events to native SwiftUI inputs. They
check multiline and single-line fields, secure fields, numeric hardware Return,
search, rename alerts, refocusing, multiline paste, and an Arabic app locale.
Return must dismiss editing without changing text, saving, submitting, or moving
focus. Explicit Save buttons must still work. The Done-key test taps the software
key when it is onscreen, otherwise sends hardware Return.

Automatic screenshot capture is disabled in the generated scheme. Do not enable
it or add screenshot attachments when running these tests.

## Run

From the repository root with Xcode 26 and XcodeGen installed:

```sh
keyboard_test_dir=$(mktemp -d /tmp/aperture-keyboard-ui.XXXXXX)
xcodegen generate --spec Scripts/KeyboardReturnUITests/project.yml --project "$keyboard_test_dir"
xcodebuild -project "$keyboard_test_dir/KeyboardReturnFixture.xcodeproj" \
  -scheme KeyboardReturnFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$keyboard_test_dir/DerivedData" \
  -parallel-testing-enabled NO test
```

Run the same command with an iPad simulator destination to verify tablet
keyboard behavior. The fixture is not a target or dependency of the shipping
Aperture app.

## Complementary checks

- `EVMWalletTests/NativeKeyboardReturnTests.swift` exercises UIKit's delegate
  contracts, validation forwarding, selections, deletion, secure entry,
  coordinator replacement, and weak ownership. Its native SwiftUI host covers
  phone/tablet portrait and landscape, both appearances, Dynamic Type, and RTL.
  It also opens the production Send Recipient route and verifies that Return
  dismisses editing without advancing its navigation stack.
- `Scripts/tests/test_text_input_return.py` inventories every production
  `TextField`, `SecureField`, `TextEditor`, and `.searchable` declaration. It
  rejects uncovered inputs and screen-level Return actions that could save or
  navigate. It also guards the root observers for native alert/search inputs.

```sh
python3 -m unittest discover -s Scripts/tests -p test_text_input_return.py
```

## Verification — 2026-08-26

- iPhone 17 Pro, iOS 26.5: all 9 keyboard-driven UI tests passed.
- iPad Pro 11-inch (M5), iOS 26.5: all 9 keyboard-driven UI tests passed.
- Aperture's signed iPad simulator test host: all 81 tests in the Return-key,
  app-language layout, Send note focus, sensitive-content lifecycle, recipient
  entry, and wallet entropy suites passed. The Return-key suite contains
  10 tests, including the production Recipient route in phone/tablet layouts.
- Release simulator build passed.
- Input inventory: all 36 production input/search declarations are covered;
  all 5 inventory tests passed. The 47 native-list color guards and 5 Keychain
  signing-configuration tests also passed using `/usr/bin/python3`.

Broader checks are not all green: `NativeSendEntryNavigationTests` failed its
accessibility-identifier lookups in the programmatic native host. The separate
production Recipient Return test passed using native input and navigation
inspection. The broad Python configuration suite also reported an ANKR fixture
missing `ANKR_NEAR_JSONRPC_PROXY_URL`; its validator and fixture were unchanged
by this task. Neither failure is included in the passing counts above.

Keep simulator signing enabled when running the wallet entropy suites. An
unsigned test-host run returned Keychain status `-34018`; rerunning with normal
simulator signing passed all 81 tests.

## Manual activation regression

The app-wide automatic-focus change has been reverted. `InitialFocusUITests`
checks that multiline, secure, and Arabic search inputs wait for a tap. It also
covers push navigation, sheets, repeated presentation, manual movement between
fields, and dismissal followed by a redraw.

The production `TextInputPresentationFocusTests` suite hosts recovery, private-key,
passphrase, Muun, Send, search, filter, and transaction screens in phone, tablet,
and large-text RTL layouts. They must open without requesting a first responder.
The converter restores its last-used currency, and the earlier Broadcast,
Find Last Recovery Word, and dedicated Send note focus behavior remain covered by
separate suites. `test_initial_input_focus.py` limits the presentation-focus hook
to those previously requested tools and rejects the removed blanket search and
scroll-to-input helpers. Native rename alerts retain UIKit behavior.

Earlier autofocus verification, before the revert (2026-09-05): the signed iPhone simulator passed all
48 production screen/layout cases plus the converter and Send-note suites
(6 test functions, 60 cases total). The iPad simulator passed all 12 keyboard UI
tests. The production options/currency fixture also passed automatic top-toolbar
search focus and Back-with-keyboard dismissal on iPad (2 UI tests). Both input
inventory suites passed (7 checks). No screenshots were captured.

Autofocus-revert verification (2026-09-05): all 57 production screen/focus cases
and all 3 manual-activation UI tests passed on each of iPhone 17 Pro and iPad Pro
11-inch (M5), iOS 26.5. Coverage includes large-text RTL, the converter's last-used
currency, Settings-tool list refresh after keyboard dismissal, Arabic search,
push navigation, and repeated sheet presentation. Both input inventory suites
passed (7 checks). Automatic screenshots remained disabled.
