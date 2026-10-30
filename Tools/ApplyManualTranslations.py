#!/usr/bin/env python3
"""Validate and integrate directly authored locale files, entirely offline.

Each locale must contain every current catalog row. No network clients, English
seeding, partial application, or translation-service candidates are supported.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import json
from pathlib import Path

from CheckLocalizationCatalog import (BRANDS, INFLECTED_BRANDS, audit_catalog,
                                      normalized, source_keys, structure_errors)

ROOT = Path(__file__).resolve().parent.parent
TABLES = ('Localizable', 'InfoPlist', 'LanguageNames')
PERMISSIONS = {'NSFaceIDUsageDescription', 'NSCameraUsageDescription'}


def prepare(root: Path, directory: Path):
    registry = json.loads((root / 'Design/Localization/languages.json').read_text())
    codes = {row['code'] for row in registry}
    catalogs = {name: json.loads((root / f'OathApp/Resources/{name}.xcstrings').read_text()) for name in TABLES}
    sources = {}
    for name, catalog in catalogs.items():
        for key, entry in catalog['strings'].items():
            if name == 'InfoPlist' and key not in PERMISSIONS:
                continue
            if entry.get('shouldTranslate') is False:
                continue
            sources[f'{name}/{key}'] = entry['localizations']['en']['stringUnit']['value']
    shared = {name: {} for name in TABLES}
    errors = []
    key_source = root / 'OathAtmosphere/Localization/OathStringKey.swift'
    if key_source.exists():
        for key in sorted(source_keys(key_source.read_text()) - set(catalogs['Localizable']['strings'])):
            errors.append(f'Localizable/{key}: OathStringKey has no catalog entry')
    staged = deepcopy(catalogs)
    for code in sorted(codes):
        path = directory / f'{code}.json'
        if not path.exists():
            errors.append(f'{code}: missing manually authored locale file')
            continue
        locale = json.loads(path.read_text())
        if locale.get('locale') != code or locale.get('method') != 'manual-agent-translation':
            errors.append(f'{code}: invalid locale or authorship method')
            continue
        values = locale.get('translations', {})
        reasons = locale.get('sharedSpellingReasons', {})
        if set(values) != set(sources):
            errors.append(f'{code}: missing {len(set(sources)-set(values))} rows; extra {len(set(values)-set(sources))} rows')
        for identity, source in sources.items():
            value = values.get(identity)
            if not isinstance(value, str) or not normalized(value):
                if identity in values:
                    errors.append(f'{code}/{identity}: empty or invalid text')
                continue
            if code == 'en' and value != source:
                errors.append(f'{identity}: English source changed during translation')
            for issue in structure_errors(source, value, allow_bidi_additions=True):
                errors.append(f'{code}/{identity}: {issue}')
            name, key = identity.split('/', 1)
            staged[name]['strings'][key]['localizations'][code] = {'stringUnit': {'state': 'translated', 'value': value}}
            if code != 'en' and normalized(source) == normalized(value):
                reason = reasons.get(identity)
                if isinstance(reason, str) and reason.strip():
                    shared[name].setdefault(key, {})[code] = reason
    if not errors:
        for name, catalog in staged.items():
            errors.extend(audit_catalog(name, catalog, codes, shared[name]))
    return staged, shared, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    catalogs, shared, errors = prepare(args.root, args.directory)
    if errors:
        for error in errors[:50]:
            print(error)
        raise SystemExit(f'Refusing incomplete integration: {len(errors)} findings. No catalogs changed.')
    if args.apply:
        for name, data in catalogs.items():
            (args.root / f'OathApp/Resources/{name}.xcstrings').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        (args.root / 'Design/Localization/shared-values.json').write_text(json.dumps(shared, ensure_ascii=False, indent=2) + '\n')
    print(f'Validated {len(catalogs)} complete manually authored catalogs; applied={args.apply}.')


if __name__ == '__main__':
    main()
