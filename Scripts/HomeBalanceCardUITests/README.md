# Home balance card simulator fixture

This isolated XcodeGen app compiles the production balance card, animated mesh style, and numeric balance presentation. It uses synthetic amounts and small in-memory formatting/privacy dependencies; it does not load wallet data or access the network.

The fixture bundles the production English/Arabic catalogs and the production adaptive semantic balance-card colors. UI tests verify the real card buttons, privacy accessibility values, QR hit area, large amount changes, RTL, and accessibility text in dark appearance. Simulator unit tests in `OathTests/WalletHomeBalanceCardTests.swift` separately inspect narrow layouts, rendered text for truncation, and precise card geometry.

Generate and test from the repository root using a selected simulator:

```sh
fixture_dir=$(mktemp -d /tmp/aperture-balance-card-ui.XXXXXX)
xcodegen generate --spec Scripts/HomeBalanceCardUITests/project.yml --project "$fixture_dir"
mkdir -p "$fixture_dir/App"
cp Scripts/HomeBalanceCardUITests/App/Info.plist "$fixture_dir/App/Info.plist"
xcodebuild -project "$fixture_dir/HomeBalanceCardFixture.xcodeproj" \
  -scheme HomeBalanceCardFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$fixture_dir/DerivedData" \
  -parallel-testing-enabled NO test
```

The scheme disables automatic screenshots; the tests never capture screenshots or record video. English and Arabic accessibility-size tests run the same production controls on iPhone or iPad. Set `APERTURE_FIXTURE_NARROW=1` when launching the fixture to constrain its available width to 320 points.
