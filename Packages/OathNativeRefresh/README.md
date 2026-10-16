# OathNativeRefresh

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
indicator remains a separate small hosting controller; UIKit objects are created
once by the attachment, not on each transient SwiftUI View initialization.
Do not add a second `.refreshable` modifier or adjust content insets manually.

## Branded indicator

The default `.system` mode retains the original native spinner. Home and Asset Detail opt into
`.oathLogo`, which hides that spinner and places the same noninteractive
54-point-wide vector inside the actual `UIRefreshControl`. The native control
owns its frame, navigation/safe-area adjustment, reveal, and collapse. There is
no scroll-overlay positioning or manually supplied toolbar inset. Both screens
use this shared attachment. Asset Detail's refresh identity includes wallet,
asset and address so a changed receive address cancels the previous presentation.

`RefreshCycle` owns pull, loading, result, and return states. Overscroll fills the
logo bottom to top, but only the native `.refreshable` activation starts touch
refresh. Holding or reversing a pull never starts wallet work on a custom
threshold. A short pull drains as UIKit springs back. Repeated native events
cannot start a second action, and the result cannot rearm until the scroll
reaches rest. Touch refresh never sets the content offset or writes content
insets. The explicit VoiceOver refresh action uses UIKit's animated offset API
to reveal the indicator.

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

Run expensive work in an actor or another appropriate background executor inside
the async action. The callback starts immediately; UI coordination stays on the
main actor. After work completes, a cancellable display-link gate waits until the
finger and native scroll movement settle before ending refresh. A 400 ms display
floor prevents fast completions from making the indicator flash or disappear.
Long-running work does not get an additional 400 ms wait on completion.

The result remains visible for at least 650 ms before UIKit ends refresh. Removing
the component, changing wallet identity, disabling refresh, or leaving the active
scene cancels the task and any presentation wait. Request identity checks discard
late completions. Home also retains its wallet-session generation guards.

Disabling is a transition, not a recurring side effect of every representable
update. Stopping an idle indicator does not mutate its observable cycle or call
`endRefreshing()`. An unconditional in-place `cycle.reset()` from
`updateUIViewController` caused a main-thread observation feedback loop while
Home was locked, preventing the passcode's first frame from being presented.
The separate indicator host receives only public presentation environment values.

Host checks (no simulator):

- `python3 Tools/CheckRefreshActions.py` runs the production asynchronous action
  boundary with delayed callbacks. It covers cancellation before work starts,
  cancellation after work starts, wallet/screen ownership changes, late success
  and failure, URLSession cancellation, current failures and diagnostic privacy
  and correlation. Obsolete UI requests do not emit new UI errors or feedback;
  underlying provider reporting is unchanged. Each refresh has an operation ID.
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
AGENTS.md, it creates one isolated iPhone 17 Pro Max simulator and launches only
a synthetic fixture with the production refresh package and native navigation
bars. Real pull gestures check Home, a pushed asset screen, repeated refresh,
failure recovery, and the system-spinner baseline. Coordinate taps check empty
space above the buttons and their visible centers before, during and after
refresh on Home and a pushed Asset screen. A 500-row fixture rejects eager
materialization. It uses the production header layout. During refresh it verifies
that the logo is a centered child of `UIRefreshControl` below the navigation bar;
after completion it checks that the scroll returns to rest. It retains XCTest
results and removes only its own simulator. No wallet or network data is used.

The known-failing unmodified ScrollView diagnostic is skipped in the default
suite. Run it deliberately with `--unmodified-baseline --only-testing
PlacementUITests/PlacementUITests/testUnmodifiedSwiftUIRefreshTouchBaseline` to
compare OS behavior. Coordinate tests hold synthetic work open and pause only
indicator-layer animations to let XCTest deliver deterministic taps. Native
scroll motion, button layout and hit testing are unchanged; separate placement
checks exercise the full branded animation and its normal completion.
