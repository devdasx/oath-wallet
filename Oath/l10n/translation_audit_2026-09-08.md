# App-wide localization audit — 2026-09-08

Scope: the existing Aperture app in `Oath`, including its 57 shipped locales,
Localizable/InfoPlist catalogs, Siri shortcut catalog, and 736 Swift files.
Independent app directories were not changed.

## Corrections

86 values were corrected across 50 non-English catalogs and 15 keys. The other
shipped catalogs already had translations for these labels.

| Key or group | Corrected values |
| --- | ---: |
| Sui network name | 42 |
| Token placeholder | 18 |
| Repository View label | 5 |
| Build label | 5 |
| Version label | 1 |
| Generic notification title | 2 |
| Activity amount placeholder | 1 |
| Custom Send fee placeholder | 5 |
| Hindi Send amount/asset template | 1 |
| Filipino private-key requirements | 2 |
| Filipino Send/XRP explanatory messages | 4 |

No English keys were added, removed, or changed. English snapshot, previous
snapshot, archive, and memory remain preserved through `audit_en_keys.py`.

## Audit improvements

The prior blanket `asset.*` / `network.*` exemptions and exemptions for formerly
invariant labels concealed untranslated descriptive copy and obsolete English
values. Canonical asset and protocol names are now exempt by explicit key and
source value. A change to descriptive copy re-enables translation checking.
Descriptive notification, repository, amount, security, and version/build labels
are checked. Legitimate shared spellings and technical loanwords are scoped to
the exact locale, key, and source value rather than exempted across all locales.

The hardcoded-copy scan now covers UIKit alert/button titles, text/placeholder
and accessibility assignments, `setTitle`, and `LocalizedStringResource`, in
addition to existing SwiftUI surfaces. An independent scan reviewed multiword
Swift literals, potential localization-key references, and remaining English
phrase matches. No additional app-owned hardcoded user-interface copy was
identified. English protocol identifiers, API error matching, diagnostic text,
previews, proper names, and localized-resource English defaults are not UI
translation omissions. Technical loanwords within translated prose are retained
where appropriate.

## Verification

- 2,033 English Localizable keys, with complete coverage in all 57 locales.
- 4 InfoPlist keys per locale and all 6 Siri shortcut phrases checked.
- 1,153 Swift localization references validated.
- No missing keys, obsolete English fallbacks, placeholder mismatches,
  malformed entries, or detected hardcoded UI literals.
- All 15 localization regression tests passed, including newly covered UIKit,
  namespace exemptions, stale values, shared spellings, and numeric placeholders.
- Isolated Aperture Debug simulator build succeeded.
- All 114 built Localizable/InfoPlist catalogs were decoded and compared
  value-for-value against source catalogs, covering every shipped locale.
- Existing Swift concurrency warnings in `WalletTextInputReturnKey.swift` remain
  outside this localization change; the build produced no errors.

Automated/source review establishes coverage and detects specific translation
faults; it is not a native-speaker linguistic certification of every sentence.
No screenshots were taken, no funds moved, and no app installation was performed
for this audit.
