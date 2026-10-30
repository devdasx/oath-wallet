# Shared empty states

Use `OathEmptyState` for empty lists, no search results and full-content
unavailable states. Its circle, SF Symbol, title, description, spacing, semantic
colors and optional actions live in `OathAtmosphere/OathEmptyState.swift`.
Keep existing localized strings and accessibility identifiers at the call site.
Do not add a second visual style or use `ContentUnavailableView` directly.

## Placement

- Full pages and list overlays use `OathEmptyStateScrollView { ... }`.
- Pages with a form, introduction or filters use its `header` and `content`
  builders. The header stays at the top; the empty state centers in the remaining
  viewport. Use `centersContent: false` when showing populated rows.
- Content-sized sheets use `OathEmptyState` directly. It retains its intrinsic
  height so UIKit can measure the sheet without requesting a full-height detent.
- An existing custom scroll surface can use `OathEmptyStateLayout` with a header,
  content and optional footer. Offer it the actual available height. The asset
  page does this through `OathFadingScrollContent(fillsViewport: true)` when empty.
- UIKit's language table hosts this same component in its background view.

The layout measures headers and text in the current pass. It does not depend on
screen models, fixed vertical spacers, scroll offsets or geometry-to-state writes.
When content cannot fit, its natural height determines the scroll extent. This
keeps long translations and keyboard-constrained layouts reachable.

Integrated surfaces: recipient address book, send asset picker, contacts and
contact addresses, contact network picker, wallet asset/token search, transaction
history and its filters, asset activity, Recently Deleted, all-wallet backup,
iCloud restore, import network search, currency search, language search, and
wallet/settings startup failures.

Missing individual prices, optional metadata, validation messages, loading
indicators and partial-result retry footers remain inline statuses. They are not
empty screens. Empty data/search results are expected states and do not generate
diagnostics. Existing error owners continue reporting through OathDiagnostics.

## Host checks

```sh
swiftc OathAtmosphere/OathEmptyState.swift OathAtmosphere/OathEmptyStateLayout.swift \
  OathAtmosphere/Home/OathHomeBodySurface.swift Tools/CheckEmptyStates.swift \
  -o /tmp/oath-check-empty-states
/tmp/oath-check-empty-states
```

These checks render the production layouts on the Mac host and check header and
footer clearance, vertical centering, compact/large viewports, RTL, content
overflow, populated-list layout and the asset page's nested available space.
The color/font bridges only enable host rendering; this is not an iOS visual or
physical-device test.
