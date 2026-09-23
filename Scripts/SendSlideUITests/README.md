# Slide to Send native touch regression

This isolated fixture compiles the production slider files directly,
including the directional text shimmer and its native text renderer.
The callback only increments an in-memory counter. It has no wallet, Keychain,
network, signing, or broadcasting dependencies. Semantic colors and native
glass match the production helpers. `UniHaptic` and `UniHapticActionFeedback`
compile directly from production, so a physical iPhone exercises the same
native feedback generators and haptic preference/foreground safeguards.

Tests use real XCUITest touch drags in English and Arabic, including repeated
full slides, vertical drift, partial/vertical gestures, taps, disabled state,
release below/above the 90% threshold, and holding at the endpoint without
committing until finger release. Dedicated handle tests cover taps, a long
press without travel, cancellation at 35% and 88%, and retrying from the
starting position in both English and Arabic. The scheme disables automatic
screenshots. The tests do not take screenshots or record video.

Release now shows the native DrawOn checkmark before invoking the callback.
Hosted completion tests run the actual symbol animation and Reduce Motion
fallback, assert that completion is not immediate, verify one delivery across
view updates, and cancel an in-flight animation without invoking Send.

Hosted native geometry tests measure the production thumb-placement modifier
at the start, intermediate progress, 90%, the endpoint, and while retreating.
They verify containment and actual rendered direction in LTR/RTL at phone and
tablet control widths; callback-count tests alone cannot catch a misplaced
thumb whose logical completion math remains correct. The production label is
also measured before, during, and after the 90% ready state in both reading
directions, at phone/tablet widths and default/accessibility text sizes. Its
bounds must remain stable so changing to release guidance cannot resize the
track under a held finger.

End-stop probes measure the production pressed-thumb artwork and its independent
gesture overlay at 0%, 50%, 90%, just before the end, and 100%, in both reading
directions and with Reduce Motion on/off. They verify that the dock contact stays
inside the capsule and compression leaves the hit area and travel unchanged.
Return-duration checks cover short/long drags and invalid geometry.

Endpoint regression probes measure continuity across 90% and 100% in both
directions. They also observe native SwiftUI transactions during held progress
updates and reversals: progress must not restart a timed catch-up animation.
Pickup remains separately animated; finger-owned deformation stays direct.

`SendSlidePerformanceTests` measures repeated Arabic endpoint/cancellation drags
with native `XCTHitchMetric` and `XCTCPUMetric`, using three measured iterations.
Run it on the same physical iPhone before and after an interaction change with
`-only-testing:SendSlideUITests/SendSlidePerformanceTests`. These measurements
detect rendering/CPU regressions; zero hitches alone cannot prove correct motion
continuity or subjective feel. Use the geometry and transaction probes as well.

Guidance tests cover the actual shared animator starting after readiness,
stopping on contact, and restarting after cancellation in LTR/RTL. A hosted
TextRenderer probe observes interpolated drawing phases and shaped glyph
coordinates for English/Arabic text without capturing any images. Directional
opacity checks verify that the shimmer highlights the reading-direction edge
first and keeps the whole instruction visible. These checks catch animation
startup failures that successful drag/submit tests cannot detect.

From the repository root:

```sh
fixture_dir=$(mktemp -d /tmp/aperture-send-slide-ui.XXXXXX)
xcodegen generate --spec Scripts/SendSlideUITests/project.yml --project "$fixture_dir"
Scripts/xcodebuild_isolated.sh test \
  -project "$fixture_dir/SendSlideFixture.xcodeproj" \
  -scheme SendSlideFixture \
  -destination 'platform=iOS Simulator,name=Aperture iOS 27 Final Validation' \
  -parallel-testing-enabled NO
```

Use Simulator for routine testing and profiling. Physical-device commands below
are only for a current, explicit user request to test on that physical device.

The default configuration remains unsigned for simulators. To validate on an
unlocked, paired development iPhone, use its device ID with these signing
overrides (the dedicated fixture bundle IDs never replace Aperture):

```sh
Scripts/xcodebuild_isolated.sh test \
  -project "$fixture_dir/SendSlideFixture.xcodeproj" \
  -scheme SendSlideFixture \
  -destination 'platform=iOS,id=CONNECTED_DEVICE_ID' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=C5T44SZNQX CODE_SIGN_IDENTITY='Apple Development' \
  -only-testing:SendSlideUITests/SendSlideUITests/testHandleTapsAndCancelledSlidesRemainReusableInBothDirections \
  -only-testing:SendSlideUITests/SendSlideUITests/testHoldingAtEndWaitsForFingerReleaseBeforeSending \
  -only-testing:SendSlideUITests/SendSlideUITests/testReleaseBelowNinetyPercentCancelsAndAboveItSends
```

Device automation verifies touch behavior and exercises native haptics; a
person holding the iPhone must judge the subjective haptic feel. All completed
slides still change only the fixture's in-memory counter and send no funds.

Rendering and release acceptance share the same horizontal projection from
`SendSlideDragTracking`. It recognizes the initial axis once per touch; an
accepted horizontal slide stays horizontal through vertical drift and manual
return. An initially vertical gesture is rejected until the next touch.
Return regressions cross the old `abs(x) == abs(y)` boundary in both directions
and with positive/negative drift, checking continuous displacement, new-touch
reset, invalid samples, and exact release acceptance after returning/re-advancing.
Only the final release position can commit at 90% or above. Earlier progress
never latches an intent to send; moving back below the threshold cancels.
`SendSlideGestureTests` covers that return-and-cancel sequence and exact 90%
boundaries. Native touch tests preserve the vertical-drift regression and verify
that a three-second hold at the end does not activate before release.
