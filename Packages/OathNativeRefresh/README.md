# OathNativeRefresh

Current release: [4.1.14 (98) verification record](../../releases/4.1.14.md). Historical checks below describe their original scope; they are not an independent audit of this release.


iOS 17+ native SwiftUI `List` with its native `.refreshable` control, exposed
through the existing `NativeRefreshScroll` API. Native reusable cells keep both
rendered content and button hit testing in the same coordinate space during the
refresh inset animation. The list has no added row insets, backgrounds, spacing,
or separators; each screen supplies its existing appearance.

A coordinate-tap regression reproduced a 60-point mismatch in an unmodified
SwiftUI `ScrollView.refreshable`: tapping 44 points above a displayed button
activated it while refresh was open. Attaching UIRefreshControl directly to that
ScrollView and adding geometryGroup did not correct it. Native List passed the
same before/during/after coordinate checks without touch interception, adjusted
hit regions, manual content offsets, or disabling the buttons during refresh.

SwiftUI owns cell reuse, environment and scrolling. A small viewport background
attachment observes public UIKit scroll geometry and styles the native control;
it never replaces the scroll delegate, pan gesture or content host. It locates
the refreshable scroll in its nearest owning UIKit view branch and assigns its
accessibility identifier, without private class names or touch overrides.
The attachment is outside the reusable rows so scrolling them offscreen does not
remove the refresh owner. There is no full-height UIHostingController measuring
every asset offscreen.

Long collections MUST be direct `ForEach` rows in the content builder. Putting
an entire LazyVStack into a single List cell materializes the whole collection.
Home separates its existing rounded header from its reusable asset rows; search
keeps its own non-refreshing scroll layout. Asset details have a bounded activity
preview. Permissions uses this same component for its pull-to-refresh screen.

`NativeRefreshScroll` accepts content, tint, scroll identifier, offset callback,
async throwing refresh action, and failure callback. The existing branded
indicator uses `UIHostingConfiguration` as a small native content view; UIKit
objects are created once by the attachment, not on each transient SwiftUI View
initialization. The refresh control can move under a navigation controller
without reparenting a separate SwiftUI hosting controller.
Do not add a second `.refreshable` modifier or adjust content insets manually.

## Pull-to-refresh indicators

The default `.system` mode retains the original native spinner. Home and Asset Detail opt into
`.progressRing`: a 28-point circular stroke fills with the pull distance, then
rotates while refreshing. Its 96-point fill threshold starts work and the started
haptic immediately, even while the finger remains down. Drawing and activation
share the same progress, so no extra pull is required after the stroke fills.
The logo and system styles retain UIKit's native activation. Pull-step haptics
follow progress and respect the app preference.

Both indicators stay inside the actual `UIRefreshControl` throughout pull,
loading, result and dismissal. UIKit owns the native reveal, refresh inset and
return motion. There is no viewport transfer, early endRefreshing on release,
custom content-offset animation or gesture cancellation. The native inset stays
open until the indicator finishes, exactly as with the logo. The ring retains
its loading stroke and ring-to-check blur replacement; those visual effects do
not animate the surrounding layout. Reduce Motion keeps the loading arc static.

`RefreshCycle` owns visual pull, loading, result and return state. A full stroke
starts work only during an eligible active drag. Later native callbacks join that
same request without duplicating work or feedback, and the gesture-start
gate still prevents scrolling from the bottom back to the top from refreshing.
Short pulls drain as UIKit springs back. The explicit VoiceOver action can start
without a drag and uses UIKit's animated offset API to reveal the control.

A returning result is visual state and does not own a native refresh. UIKit can
reactivate its control if another pull interrupts the return; when no request is
active, that native event must end the control without starting more work. Otherwise its inset holds the
scroll away from zero while the cycle waits for zero to clear the checkmark.
An event belonging to an active request remains attached to that request.

`OathRefreshMark` reproduces the two supplied SVG ring masks as a cached native
`Shape`. On iOS 26+, Apple's `.glassEffect(.clear, in:)` renders the actual logo
outline; earlier systems use native material. A small, separate color layer fills
the shape and flows at 30 frames per second only while actively refreshing. The
glass shape and Home do not redraw on those animation ticks. There are no downloaded
assets, raster snapshots, or custom shader filters.

Successful work replaces the logo with SF `checkmark` using native `.blurReplace`.
Failure shows `exclamationmark` before the failure callback, never a success check.
Reduce Motion uses static colors and a fade; Reduce Transparency uses an opaque
vector. Labels and VoiceOver completion announcements are supplied by the caller.

Home and Asset Detail use `timing: .brief`: the loading ring runs for 2.5 seconds,
then blur-replaces the ring with a check and holds it briefly while provider work continues.
A timed check acknowledges the gesture (`.finished` feedback); it does not
announce “Updated” while data is still loading. Already-known failures show the
error state instead. Callers route feedback through the shared haptics preference.
A separately owned action keeps updating data after the indicator collapses;
another pull reuses it while it is running. Late failures still reach shared
diagnostics and the failure callback, without replaying haptics or the animation.

The default `timing: .untilFinished` retains the following completion behavior:
Run expensive work in an actor or another appropriate background executor inside
the async action. The callback starts immediately; UI coordination stays on the
main actor. After work completes, a cancellable display-link gate waits until the
finger and native scroll movement settle before ending refresh. A 400 ms display
floor prevents fast completions from making the indicator flash or disappear.
Long-running work does not get an additional 400 ms wait on completion.

The logo result remains visible for at least 650 ms. The ring completes its
500 ms circle-to-check transition, then holds the result for 800 ms before the
indicator closes. UIKit then collapses its refresh inset. In both timing modes, removing
the component, changing wallet identity, disabling refresh, or leaving the active
scene cancels the task and any presentation wait. Request identity checks discard
late completions. Home also retains its wallet-session generation guards.

Disabling is a transition, not a recurring side effect of every representable
update. Stopping an idle indicator does not mutate its observable cycle or call
`endRefreshing()`. An unconditional in-place `cycle.reset()` from
`updateUIViewController` caused a main-thread observation feedback loop while
Home was locked, preventing the passcode's first frame from being presented.
The indicator content view receives only public presentation environment values.

`testRingUsesNativeControlOnHomeAndAsset` samples the entire finite refresh and
checks that the ring never leaves the native control and the control never ends
early. It also checks native placement, return to rest and visible button targets
after completion, with all animations enabled. `testLogoNativeControlBaselineOnHomeAndAsset` checks
the original logo's native placement and return on the same header layout with
a finite provider. The timed-ring test verifies the 2.5-second check and
continuing background work.

Host checks (no simulator):

- `Tools/CheckRefreshRing.swift`, compiled with `RefreshCycle.swift`, covers exact
  activation at exact full fill, partial cancellation, native-event deduplication,
  held gestures, bounce, failure, rearming and accessibility activation.

- `python3 Tools/CheckRefreshActions.py` runs the production asynchronous action
  boundary with delayed callbacks. It covers cancellation before work starts,
  cancellation after work starts, wallet/screen ownership changes, late success
  and failure, URLSession cancellation, current failures and diagnostic privacy
  and correlation. Obsolete UI requests do not emit new UI errors or feedback;
  underlying provider reporting is unchanged. Each refresh has an operation ID.
  It also tests the production 2.5-second timer, fast/slow providers, coalescing
  further pulls, late failure reporting and invalidation of background actions.
- `Tools/CheckRefreshCompletion.swift`, compiled with `RefreshCompletion.swift`,
  covers gesture settlement and loading/result display intervals.
- `Tools/CheckBrandedRefresh.swift`, compiled with `RefreshCycle.swift` and
  `OathRefreshMark.swift`, covers state transitions, cancellation/reset, duplicate
  activations, and vector geometry against independent SVG ring equations.
- `Tools/CheckRefreshObservation.swift`, compiled with `RefreshCycle.swift` and
  `RefreshIndicatorModel.swift`, checks actual Observation notifications across
  20,000 idle stops and active/partial-refresh cancellation.

`LocalizationTests/OathRefreshInterruptionTests.swift` is a focused UIKit runtime
regression. With synthetic success and failure actions, it holds a nonzero offset
through the result's return and delivers a second native threshold event. It
checks ownerless control cleanup, preservation of owned requests, and the next
refresh after rest. It requires a simulator; the host checks above do not.

Original SVGs and the prior implementation are preserved with SHA-256 hashes in
`Design/Refresh/Before-Branded-Refresh/`. Set Home's indicator to `.system` to switch
back without changing the refresh action. See that folder's README for restoring
the exact previous source.

## Performance regression

`Tools/CheckHomeScrollRuntime.py` builds an isolated synthetic probe with the
production scroll package and Home header layout. It requires a justified
simulator check under AGENTS.md. It creates/deletes only its own simulator and
never loads wallet data. The fixture verifies visible-row realization, native
scroll callbacks and system/branded refresh completion. Duplicate suppression
is also covered by the host lifecycle checks above.
Host database/presentation benchmarks are documented in
`Documentation/HomePerformance.md`.

`python3 Tools/CheckNativeRefreshPlacement.py --simulator-check --output /tmp/oath-refresh-placement`
is the focused placement regression. After stating the runtime uncertainty under
AGENTS.md, it creates one isolated iPhone 17 Pro Max simulator by default
(`--device-type com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max` selects iPhone 18 Pro Max) and launches only
a synthetic fixture with the production refresh package and native navigation
bars. Real pull gestures check Home, a pushed asset screen, repeated refresh,
failure recovery, and the system-spinner baseline. Coordinate taps check empty
space above the buttons and their visible centers before, during and after
refresh on Home and a pushed Asset screen. A 500-row fixture rejects eager
materialization. It uses the production header layout. During refresh it verifies
that the logo is a centered child of `UIRefreshControl` below the navigation bar;
after completion it checks that the scroll returns to rest. It retains XCTest
results and removes only its own simulator. No wallet or network data is used.

The row-visibility regression also swipes away from and back to the header four
times and inspects rendered marker pixels in visible asset cells. Accessibility
existence alone cannot detect an oversized header background painting over rows.
The production header uses a native stack and a body-sized background; it never
extends that background into sibling list cells.

The Home/Asset fixture additionally checks bottom-bounce pixels during a real
held native drag, confirms header artwork remains visible at the top, and
checks for a shadow seam on returning to the first row. Its production background
uses SwiftUI anchor preferences to reveal the fixed artwork only behind the
header, with an opaque body-colored viewport underneath the complete List.
It does not extend a reusable header cell beyond its measured bounds or add
scrollable filler to cover overscroll. Rendering/geometry samples exist only
in this synthetic test app and never read real wallet data.

The known-failing unmodified ScrollView diagnostic is skipped in the default
suite. Run it deliberately with `--unmodified-baseline --only-testing
PlacementUITests/PlacementUITests/testUnmodifiedSwiftUIRefreshTouchBaseline` to
compare OS behavior. Coordinate tests hold synthetic work open and pause only
indicator-layer animations to let XCTest deliver deterministic taps. Native
scroll motion, button layout and hit testing are unchanged; separate placement
checks exercise the full branded animation and its normal completion.

## Live reading-direction changes

Callers attach `.id(strings.language.isRightToLeft)` to the concrete
`NativeRefreshScroll` call. This renews its native List and refresh attachment
together when changing between RTL and LTR, while the parent owns wallet/session,
filters, drafts and navigation state. Do not put this identity on the scene,
wallet session or NavigationStack. Scroll position and row-local transient state
can reset on a direction change; same-direction language changes retain identity.

`UIHostingConfiguration` owns the indicator's SwiftUI view without registering a
second `UIHostingController` with the containing navigation/hosting controller.
The prior controller bridge retained stale collection content during language
changes in the regression fixture; large-title navigation also exposed a UIKit
controller-containment exception. Native content hosting avoids both controller
ownership paths while retaining the same `BrandedRefreshIndicator` and model.

Direction changes and temporary absence of a mounted refresh control are normal
UI lifecycle events, not diagnostic failures. Existing refresh error reporting,
cancellation and operation correlation remain in `RefreshAction`.

Run `python3 Tools/CheckNativeListDirection.py` for the source guard and use
`Tools/LanguageDirectionRegression` only when runtime verification is justified.

### Native ring result presentation

The progress-ring style is hosted inside the native refresh control. Pulling
fills a 28-point stroke; actual loading uses Core Animation rotation (0.85s)
and stroke sweep (1.15s) without a system spinner or per-frame timer. Results
use SwiftUI's native `.transition(.blurReplace)` over 0.5 seconds. The outgoing
ring keeps rotating during the replacement. The check stays for another 0.8s;
failure displays an exclamation mark. Reduce Motion replaces the static arc
immediately. The brief presentation shows the check after 2.5s while work runs on.

Quarter-pull steps at 25%, 50%, and 75% emit preference-aware selection feedback.
Activation uses a soft impact, and the result uses success/error feedback after
the transition. Each step fires at most once per gesture; fast swipes emit only
the latest step, and the full threshold never emits both a step and activation.
Reversal, bounce, cancellation, loading, and repeated layout updates are silent.
No hardware feedback is produced by the rendering layer. These are ordinary UI
events, not diagnostics failures; original action failures retain shared reporting.
`Tools/CheckRefreshPullFeedback.swift` tests the discrete gesture policy on the host.

A custom pull indicator is eligible only when its pan begins at the top (within
1 point of native rounding). Eligibility stays fixed through that pan and its
release callback. Scrolling up from lower content, even past the full threshold,
shows no ring and emits no refresh haptics or work. A new pull at the top rearms it.
The controller observes offsets before the pan begins so the first UIKit movement
cannot erase the starting position. Explicit VoiceOver refresh remains available.
`Tools/CheckRefreshPullGesture.swift` covers the policy and ring integration on the
host; the isolated placement fixture covers actual UIKit event ordering on Home
and Asset Detail. Suppressed navigation gestures are expected UI behavior, not errors.
