# Home quick-actions regression tests

This isolated simulator fixture compiles the production options control,
popover, in-place flow, currency screen, native navigation container, currency
catalog, and text-input helpers directly from `EVMWallet/`. Settings and rates
use in-memory substitutes, so these tests contain no wallet secrets, database,
or networking. Automatic screenshot capture is disabled. When explicitly
authorized, record the simulator with `simctl io recordVideo` and inspect its
frames alongside the accessibility and native-geometry assertions.

UI tests exercise English and every shipped RTL language (Arabic, Persian,
Hebrew, Sindhi, and Urdu) on an English-language simulator. Coverage includes
localized selected currency names; physical icon and Back placement; repeated
Currency Back navigation and options restoration with restored dimensions; search and selection;
outside dismissal and reopening; Back while searching; top and bottom toolbar anchors; rotation;
large text with dark appearance; and the other three option handoffs.

The fixture declares the same supported orientations and minimum iOS version
as the app; the rotation test also checks the actual window dimensions.

Window-backed tests check that Settings ends at the last native list row,
with no unused footer or popover arrow, and that the native presentation bridge
animates intermediate widths and heights when expanding, returning, and
reversing a resize before it finishes. This separately checks the outer
container, which can otherwise jump even when content appears to animate.
Top/bottom lifecycle checks also require real bar-item anchors, animated UIKit
transition coordinators with matching durations in each direction, completed
dismissal callbacks, and restoration of the source item’s original frame.
The top-toolbar UI cases repeat the currency flow in English and Arabic and
check selection, outside dismissal, and button availability after rotation.

The options and currency content share one popover. There is no zoom or push
transition. UIKit animates changes to the hosting controller's preferred
content size. The menu measures its native List content; currency requests a
380-point width and 540-point height, with a larger height for Dynamic Type
and flexible minimum dimensions for small or rotated windows.

The popover resolves the originating toolbar's actual `UIBarButtonItem` through
public UIKit APIs and passes it as `sourceItem`. The lookup includes the
leading, center, and trailing navigation item groups used by SwiftUI’s top
toolbar, including a group’s visible representative item. The top-toolbar
regression originally failed on iPad because the legacy left/right item
arrays were empty and the presenter fell back to a plain view anchor. On iOS 26 this enables the
system's morph from and back into the options control. A view anchor remains
available when the control is outside a toolbar. The arrow directions are
empty. Presentation waits for the anchor's window attachment, and action
handoffs run only after dismissal completes.

Currency uses its own UIKit navigation controller, native navigation bar,
an icon-only native `UINavigationItem.backAction`, and `UISearchController`.
Back ends search and returns to the options state in the same popover,
restoring its measured size. Selecting a currency still dismisses the popover.
Search stays in the native top bar and uses integrated placement in compact
height so the keyboard cannot leave room only for the section header. Search
and the title use existing localization keys. Locale, layout direction,
appearance, and Dynamic Type are inherited from the app environment.

Apple references:

- [Popover source items and the iOS 26 morph](https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/sourceitem)
- [UIKit design session: popover presentation](https://developer.apple.com/videos/play/wwdc2025/284/?time=835)
- [Native animated popover sizing](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferredcontentsize)
- [Hosting-controller sizing options](https://developer.apple.com/documentation/swiftui/uihostingcontroller/sizingoptions)
- [Search in the navigation bar](https://developer.apple.com/documentation/uikit/uinavigationitem/searchcontroller)

Run from the repository root, selecting an available iPhone or iPad simulator:

```sh
fixture_dir=$(mktemp -d /tmp/aperture-home-menu-ui.XXXXXX)
xcodegen generate \
  --spec Scripts/HomeQuickActionsMenuUITests/project.yml \
  --project "$fixture_dir"
mkdir -p "$fixture_dir/App"
cp Scripts/HomeQuickActionsMenuUITests/App/Info.plist "$fixture_dir/App/Info.plist"
xcodebuild \
  -project "$fixture_dir/HomeQuickActionsMenuFixture.xcodeproj" \
  -scheme HomeQuickActionsMenuFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$fixture_dir/DerivedData" \
  -parallel-testing-enabled NO \
  test
```
