# English localization key cache

This folder **always caches English UI strings** so audits can detect and fix other languages when EN is **added**, **removed**, or **changed**.

Old English values are **never discarded** after a change:

1. Written to `en_keys_snapshot.prev.json` (last different EN)
2. Archived as a full dump under `en_keys_archive/`
3. Recorded forever in `en_keys_memory.json` (per-key history with old → new)

## Cache files

| File | Purpose |
|------|---------|
| `en_keys_snapshot.json` | **Current** EN baseline (`Localizable` + `InfoPlist` key→value) |
| `en_keys_snapshot.prev.json` | **Last different** EN snapshot — only updated when EN changes |
| `en_keys_archive/` | Timestamped **full** EN dumps whenever EN changes |
| `en_keys_memory.json` | Permanent per-key history: current value, first seen, every add/change/remove with **old** values |
| `en_keys_last_diff.json` | Last compare: added / removed / changed + locale gaps |
| `en_keys_history.jsonl` | Append-only log of every audit run |
| `audit_en_keys.py` | Compare live EN vs cache, check locales, refresh cache safely |

## How to run

From the repo root:

```bash
python3 Oath/l10n/audit_en_keys.py
```

Each run:

1. Diffs live `en.lproj` against `en_keys_snapshot.json`
2. Prints **added**, **removed**, and **changed** EN values (**old** vs **new**)
3. Checks locale parity (missing keys, placeholders, English stubs)
4. Writes `en_keys_last_diff.json`
5. **If EN changed:**
   - Archives the previous full snapshot → `en_keys_archive/`
   - Saves previous EN → `en_keys_snapshot.prev.json` (not overwritten on later no-op runs)
   - Appends old/new history → `en_keys_memory.json`
   - Refreshes `en_keys_snapshot.json` to live EN
6. **If EN did not change:** keeps `prev` and archives intact; still refreshes current snapshot counts/timestamp and syncs memory currents

## Why this exists

Without a durable cache, “what changed in English?” is guesswork after the next audit. With it:

- Old EN values survive every refresh
- Changed copy can be retranslated accurately in other languages
- Removed keys keep their last English source text
- New keys are listed with their English source text
