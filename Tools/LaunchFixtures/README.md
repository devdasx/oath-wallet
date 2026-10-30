# Startup scene migration regression

`Missing AppGraph` can occur after updating an installed SwiftUI application to
a UIKit `UIApplicationDelegate` entry point. iOS can retain a scene configured
with `SwiftUI.AppSceneDelegate`; the UIKit entry point does not initialize the
SwiftUI application graph that this delegate expects. The result can be a blank
launch followed by a fatal error when UIKit restores or saves the scene.
A clean installation does not reproduce that upgrade path.

Oath keeps a SwiftUI `App` / `WindowGroup` entry point and connects the local
startup-readiness work using `UIApplicationDelegateAdaptor`. The legacy
`OathSceneDelegate` class remains available for previously saved UIKit scenes.
Both delegates use the same settings, wallet, privacy, and locking lifecycle.
No production code deletes scene archives or resets the wallet to repair launch.

## Build the regression fixtures without running a simulator

```sh
python3 Tools/BuildLegacyLaunchFixture.py --lifecycle swiftui --output /tmp/OathLegacySwiftUI.app
python3 Tools/BuildLegacyLaunchFixture.py --lifecycle uikit --output /tmp/OathLegacyUIKit.app
```

The builder compiles and signs a simulator-only application. It refuses to
replace an existing output directory and never installs or launches anything.
These minimal fixtures deliberately use Oath's bundle/module names, display
only a label, and save `launchMigrationSentinel = preserved` in preferences.
They contain no wallet, credentials, or networking.

## Targeted runtime protocol

Use this only when launch migration is the unresolved runtime concern. Use one
new disposable simulator owned by this check, never a physical device or a
simulator containing a real wallet.

1. Install one legacy fixture, launch it, background it, then terminate it.
2. Install the current Oath app **over** that fixture without uninstalling. This
   retains the existing scene/session and preference sentinel.
3. Launch the updated app manually and verify the first screen. Run
   `OathLockPresentationUITests/testRestoredSceneSurvivesColdLaunchAndForeground`
   to check usable content, opening/closing a sheet, background/foreground, and
   a second cold launch. Its first pass activates the existing process.
4. Verify that the fixture preference still equals `preserved`.
5. Repeat with the other legacy fixture, clearing only the disposable test
   installation between fixture types. Also check a fresh installation.
6. Run `testColdLaunchShowsHomeAndUsableKeypad` for a saved wallet: it imports a
   public BIP39 test vector, saves Dark while the system is Light, relaunches,
   checks the locked Home and keypad, unlocks, and locks/unlocks after returning
   from the background.
7. Remove only the simulator created for this check.

For normal code validation, generic iOS compilation and simulator
`build-for-testing` do not launch a runtime. The focused runtime tests above
must not be expanded into an unrelated device or screen matrix.

Apple references:
[UIApplicationDelegateAdaptor](https://developer.apple.com/documentation/swiftui/uiapplicationdelegateadaptor)
and [asynchronous scene restoration](https://developer.apple.com/videos/play/wwdc2021/10057/?time=795).
