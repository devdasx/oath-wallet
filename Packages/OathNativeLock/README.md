# OathNativeLock

Scene-local UIKit presentation for an app-owned passcode, using
[`overFullScreen`](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/overfullscreen)
and [`UIVisualEffectView`](https://developer.apple.com/documentation/uikit/uivisualeffectview).
The existing screen and any presented sheet stay in the original window; the
native blur samples those live views. No screenshots, duplicated screens, second
windows, private APIs, or device-passcode impersonation are used. iOS does not
expose its device passcode screen for validating an app's own PIN. The host app
supplies its accessible keypad and uses Local Authentication for Face ID.

Keep the content hierarchy mounted while `isLocked` is true. Add a
`NativeLockPresentation` anchor to that scene's root. Its content closure receives
`isVisible`; automatic biometric prompts must wait for both visibility and an
active scene. Only verified authentication may change `isLocked` to false.

For a cold launch, mount `NativeInitialLock` as an overlay in the first view
hierarchy instead of scheduling a modal after Home appears. It contains the
same native blur/keypad controller as a UIKit child. Keep the overlay mounted
until its `onUnlocked` callback completes the native reveal, then use
`NativeLockPresentation` for subsequent locks above retained screens and sheets.
The app resolves its local route and saved appearance with UIKit's short
[asynchronous scene restoration extension](https://developer.apple.com/videos/play/wwdc2021/10057/?time=795)
before exposing the window. Database and Keychain reads remain asynchronous;
network/cloud work is outside this first-screen boundary. Every extension is
balanced on success, cancellation, and failure.
The bridge transfers public locale, direction, Dynamic Type, appearance and scene values;
the host supplies any app-defined environment keys on the content. It does not
copy the presenting host's internal SwiftUI environment into the new host.
It follows the host's effective light/dark choice for its UIKit traits, adaptive
blur, controls and status bar. It never forces dark mode or changes the presenting
window's appearance. Reduce Transparency also follows that same choice.

The presenter follows the scene's own modal chain, waits for ongoing transitions,
ends text editing, and presents above the topmost screen. It blocks interactive
dismissal and isolates accessibility focus. Locking is immediate. Unlocking
uses a 0.18-second, ease-out UIKit dissolve of its blur and foreground, then removes only
the transparent lock modal. Once authenticated, a visible foreground scene begins
the reveal immediately, including while Face ID is still dismissing. Apple's
[`foregroundInactive`](https://developer.apple.com/documentation/uikit/uiscene/activationstate-swift.enum/foregroundinactive)
state is still onscreen; it must not delay or suspend successful authentication.
Only backgrounding, disconnecting or disappearance suspends the reveal; a relock
cancels it and invalidates old animation completions. Starting a new biometric
request still requires an active scene. Passcode setup follows the same distinction:
completed enrollment advances once while foregrounded, without waiting for Face ID
to finish its UI. Reduce Transparency fades an opaque background, and Reduce Motion
uses a brief 0.12-second fade without translation or scale. The presenting screen
stays mounted and protected from interaction and accessibility until completion.
The successful PIN indicators stay filled throughout the reveal, while the
entered digits are erased immediately after authentication. No delay, network
request, or extra authentication step is added by the transition.

The anchor checks UIKit's actual presentation ownership after a lock disappears.
If an underlying sheet dismisses the lock as part of its own dismissal, the stale
controller is discarded and a new lock is presented while authentication is
still required. Refused presentations also retry even when UIKit omits its
completion. Old callbacks cannot clear a replacement controller. Asset navigation
stays mounted when locking so its sheets are not removed by the lock event.
`OathLockInterruptionTests` exercises external sheet dismissal, a refused
presentation, a missing completion, an authenticated dismissal without a
spurious relock, and closing a retained SwiftUI sheet. The app-level regression
checks Receive, background return and cold launch with App Switcher Privacy enabled.

The session retains display metadata and pauses its database observation when
locking; its vault clears decrypted keys and recovery material. An already
revealed recovery-phrase view retains its displayed words until confirmation or
dismissal, including in app-switcher snapshots. New reveals still require an
unlocked vault. An in-memory screen survives a normal
background/foreground visit. After process termination, the app mounts Home as
the default background using only its saved SQL display metadata, matched to the
existing vault identity. That read does not decrypt the wallet or authorize an
operation. Home, its blur, and the keypad mount together for the first frame.
Home stays disabled and hidden from accessibility until the reveal completes.
Missing legacy metadata falls back to the same Home layout and does not prevent
passcode entry. There is no intermediate welcome artwork or loading view for
an existing wallet.
