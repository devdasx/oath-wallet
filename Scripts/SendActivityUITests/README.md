# Send banner and Home pending-activity interaction tests

This isolated fixture compiles the production single-transaction Send banner,
Home activity toolbar button, native toolbar-source popover bridge, pending list,
Send row/status badge, swipe recognizer, and Send activity store. Operation data,
pending-store data, and the destination used to verify receipt selection are
simulated. Submission traps; these tests never sign, broadcast, or use a network.
The actual pending-store merge and GRDB observations are covered by
`WalletPendingActivityTests` in the app test target.

Seven native XCUITests exercise the badge/toolbar route, single banner without a
count, exact receipt selection, close and reopen, row-swipe dismissal, long-list
scrolling with Dynamic Type in English/Arabic, failure review, and rotation.
Two retained layout tests cover the earlier expanded-list sizing primitive.
These do not substitute for real provider or transaction-submission tests.

Automatic screenshot capture is disabled. No screenshots or video are created
or inspected.

```sh
fixture_dir=$(mktemp -d /tmp/aperture-send-activity-ui.XXXXXX)
xcodegen generate --spec Scripts/SendActivityUITests/project.yml --project "$fixture_dir"
Scripts/xcodebuild_isolated.sh test \
  -project "$fixture_dir/SendActivityFixture.xcodeproj" \
  -scheme SendActivityFixture \
  -destination 'platform=iOS Simulator,name=Aperture iOS 27 Final Validation' \
  -parallel-testing-enabled NO -collect-test-diagnostics never
```

The generated project stays outside the app project. The toolbar uses the
native badge and the real toolbar item as the popover source. iOS owns its
presentation and dismissal animations, including the toolbar-to-popover morph.
