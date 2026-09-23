# Home asset pin interaction regression

This isolated fixture links the production `WalletHomeAssetPinAction` and
`WalletHomeSwipeCompletion` files. It uses a native SwiftUI List with separate
pinned and regular Sections, just like Home. It contains synthetic assets only;
there is no wallet persistence, credential access, signing, or network traffic.

The UI tests perform real leading-edge swipes and tap Pin/Unpin. They cover LTR,
Arabic RTL, the reduced-motion reorder path, adding/removing the pinned section,
and moving the final regular asset into the pinned section.

The fixture samples native cell **presentation-layer** positions on display
frames. Final accessibility/model frames alone cannot detect this regression.
Assertions verify that a preference change happens after the swipe has closed,
that each action commits once, that vertical movement stays between its start
and destination, and that moves between existing sections remain animated when
enabled. Section creation/removal keeps UIKit’s own transition. The production
action also waits for native closing layer animations to finish, including the
last subpixel frames after `isSwiped` becomes false.
Screenshots and screen recordings are not captured.

```sh
xcodegen generate --spec Scripts/HomeAssetPinUITests/project.yml
Scripts/xcodebuild_isolated.sh \
  -project Scripts/HomeAssetPinUITests/HomeAssetPinFixture.xcodeproj \
  -scheme HomeAssetPinFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

Apple references:

- [View identity and moves between sections](https://developer.apple.com/videos/play/wwdc2021/10022/)
- [Native swipe actions](https://developer.apple.com/documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:))
- [Cell swipe state](https://developer.apple.com/documentation/uikit/uicellconfigurationstate-swift.struct/isswiped)
- [Rendered animation state](https://developer.apple.com/documentation/quartzcore/calayer/presentation())
