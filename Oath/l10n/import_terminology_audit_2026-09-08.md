# Import terminology review — 2026-09-08

The blocked-import action previously used “Use a Different Credential” for both recovery phrases and private keys. Both import flows now select a type-specific action:

- Recovery phrase: “Use a Different Recovery Phrase”; Arabic: “استخدام عبارة استرداد أخرى”.
- Private key: “Use a Different Private Key”; Arabic: “استخدام مفتاح خاص آخر”.

The import-method instruction and duplicate-wallet message also now refer directly to the method or wallet instead of using ambiguous credential terminology. These four strings were written for all 57 shipped locales. The old generic action key was removed from live catalogs, while its historical values remain in the English localization audit archive and memory.

## Verification

- Isolated iOS Simulator build and WalletCredentialSafetyServiceTests succeeded: 9 tests, including parameterized cases.
- Full localization validator passed for 57 locales and 1156 Swift localization references.
- Localization validator regression suite passed: 15 tests.
- English-history audit preserved prior values and reported no missing translation keys or placeholder mismatches.

The linguistic review covers these import strings and the reported terminology issue. App-wide automated checks validate catalog structure and consistency; they are not a complete linguistic review of every existing translation.
