# Exact text lifecycle regression

This isolated fixture compiles the shipping `WalletExactText`,
`WalletTextWrapping`, and `WalletNativeTextPrivacy` sources. It uses only a
synthetic 64-character identifier. No wallet storage, RPCs, credentials, or
transaction submission are linked into the fixture.

The tests cover cancellation of a full-screen authorization fixture, a nested
identifier sheet, actual Home/foreground transitions, and a system privacy
redaction request while the app's Privacy Shield setting is off. The rendering
probe checks native visibility and drawing-layer presence as well as retained
text, so a nonempty text storage alone cannot make the regression pass. It does
not capture, render, save, or inspect screenshots; automatic XCTest screenshots
are disabled in the scheme.

The old renderer fails the explicit privacy-request case with its text intact
but `isHidden == true` and no visible drawing layers. The setting-aware renderer
keeps the same identifier visible. Full-app tests in `WalletTextWrappingTests`
and `NativeSendReviewRecipientTests` additionally cover Privacy on/off updates,
placeholder masks, native recovery and receive controls, production Send and
history detail sheets, iPhone/iPad layouts, large text, RTL, and both appearances.

Generate the fixture project with XcodeGen, then run using the workspace's
isolated build wrapper and an available simulator ID:

```sh
xcodegen generate --spec Scripts/ExactTextLifecycleUITests/project.yml
Scripts/xcodebuild_isolated.sh \
  -project Scripts/ExactTextLifecycleUITests/ExactTextLifecycleFixture.xcodeproj \
  -scheme ExactTextLifecycleFixture \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -parallel-testing-enabled NO test
```

The fixture's English labels and reports are test-only controls, not app copy.

The full-app native tests traverse SwiftUI's accessibility elements in-process.
They require the simulator's application accessibility service to be enabled;
XCTest UI automation can disable that service on teardown. If both the old and
new app builds report missing controls, check that simulator setting before
interpreting those failures as a rendering regression. Preserve and restore its
prior value when running the native tests.
