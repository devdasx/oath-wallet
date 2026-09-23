# Translation audit — 2026-09-05

App version: 3.5.1 (build 46).

## Coverage and verification

| Check | Result |
| --- | --- |
| Shipped languages | 57, including English |
| Localizable.strings | 1,993 keys in every language |
| InfoPlist.strings | 4 keys in every language |
| Siri shortcuts | 6 phrases in every language |
| Missing, extra, empty, or duplicate app keys | 0 |
| Format-placeholder mismatches | 0 |
| Non-exempt English copies or obsolete English values | 0 |
| Apple .strings syntax validation | All 114 shipping files passed |
| Swift localization references checked | 1,123 |
| Localization-validator regression tests | 9 passed |

Strict key-set comparison was performed independently of the build validator's
English-fallback exemptions. Siri phrases were compared with the phrases used by
OathAppIntents.swift; every language has a translated entry with the correct
application-name placeholder.

## Corrections

- Translated descriptive currency, derivation-path, and fee labels that were
  incorrectly exempted as technical terms. Affected languages included Filipino,
  Odia, Tamil, Malayalam, Hindi, Sindhi, Swahili, Yoruba, and Simplified Chinese.
- Replaced obsolete unit-only fee values with the current translated descriptions,
  preserving technical units and format placeholders.
- Updated transfer instructions in every affected language to name the current
  localized menu actions. This also removed English menu instructions embedded
  in Nepali, Punjabi, and Georgian and aligned several translated Settings labels.
- Preserved both changed English instructions in the existing snapshot, previous
  snapshot, archive, and per-key history system.
- Narrowed translation exemptions and added regression coverage for descriptive
  technical labels, obsolete English values, Siri coverage/placeholders, and
  menu-label references. Updated send.md for the fee-localization contract.

## Boundaries

Brand names, asset/network names, protocol identifiers, and technical units remain
unchanged where intentional. Numbers retain ASCII digits. Legitimate words shared
with English, such as French “Notifications,” are not treated as missing translations.

This is a source/resource audit, with targeted wording review. It is not a
native-speaker certification of every sentence, nor a manual walkthrough of every
screen in all 57 languages. User-entered content and external provider text are not
translation-catalog entries. No new app screenshots were captured.

The unreferenced hi.lproj/Localizable_new.strings file is not part of the shipping
localization table or the inspected app bundle; it was left unchanged.

## Reproduce

```sh
python3 Oath/l10n/audit_en_keys.py
/usr/bin/python3 Scripts/validate_infoplist_localizations.py
/usr/bin/python3 -m unittest discover -s Scripts/tests -p test_validate_infoplist_localizations.py
```

Per-language counts are recorded in translation_audit_2026-09-05.json.
