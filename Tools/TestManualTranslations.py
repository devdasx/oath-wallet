#!/usr/bin/env python3
"""Host-only regressions for complete, directly authored locale integration."""
import json
from pathlib import Path
import tempfile
import unittest

from ApplyManualTranslations import prepare


class ManualTranslationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        resources = self.root / 'OathApp/Resources'
        resources.mkdir(parents=True)
        metadata = self.root / 'Design/Localization'
        metadata.mkdir(parents=True)
        (metadata / 'languages.json').write_text(json.dumps([{'code': 'en'}, {'code': 'fr'}]))
        unit = lambda value: {'stringUnit': {'state': 'translated', 'value': value}}
        self.rows = {'Localizable/send': 'Send %@ on Bitcoin', 'LanguageNames/language.english': 'English'}
        for name in ('Localizable', 'InfoPlist', 'LanguageNames'):
            data = {'sourceLanguage': 'en', 'strings': {}}
            for identity, source in self.rows.items():
                table, key = identity.split('/', 1)
                if table == name:
                    data['strings'][key] = {'localizations': {'en': unit(source)}}
            (resources / f'{name}.xcstrings').write_text(json.dumps(data))
        self.directory = self.root / 'manual'
        self.directory.mkdir()
        self.fr = {'Localizable/send': 'Envoyer %@ sur Bitcoin', 'LanguageNames/language.english': 'Anglais'}
        self.write('en', self.rows)
        self.write('fr', self.fr)
        self.before = {p: p.read_bytes() for p in resources.iterdir()}

    def write(self, locale, translations, **extra):
        value = {'locale': locale, 'method': 'manual-agent-translation', 'translations': translations, **extra}
        (self.directory / f'{locale}.json').write_text(json.dumps(value))

    def test_complete_authored_set_passes_without_writing(self):
        catalogs, _shared, errors = prepare(self.root, self.directory)
        self.assertEqual(errors, [])
        self.assertEqual(catalogs['Localizable']['strings']['send']['localizations']['fr']['stringUnit']['value'], self.fr['Localizable/send'])
        self.assertEqual(self.before, {p: p.read_bytes() for p in self.before})

    def test_used_key_missing_from_catalog_blocks_integration(self):
        path = self.root / 'OathAtmosphere/Localization/OathStringKey.swift'
        path.parent.mkdir(parents=True)
        path.write_text('enum OathStringKey {\n case send, receive\n}')
        errors = prepare(self.root, self.directory)[2]
        self.assertTrue(any('Localizable/receive: OathStringKey has no catalog entry' in e for e in errors))
        self.assertEqual(self.before, {p: p.read_bytes() for p in self.before})

    def test_missing_locale_and_missing_key_cannot_be_filled_with_english(self):
        (self.directory / 'fr.json').unlink()
        self.assertTrue(any('missing manually authored' in e for e in prepare(self.root, self.directory)[2]))
        self.write('fr', {})
        self.assertTrue(any('missing 2 rows' in e for e in prepare(self.root, self.directory)[2]))

    def test_nonmanual_candidate_is_rejected(self):
        self.write('fr', self.fr, method='machine-translation')
        self.assertTrue(any('authorship method' in e for e in prepare(self.root, self.directory)[2]))

    def test_invisible_copy_and_disguised_english_are_rejected(self):
        self.write('fr', {**self.fr, 'Localizable/send': '\u2066Send  %@ on Bitcoin\u2069'})
        self.assertTrue(any('identical to English' in e for e in prepare(self.root, self.directory)[2]))
        self.write('fr', {**self.fr, 'LanguageNames/language.english': '\u2066\u2069'})
        self.assertTrue(any('empty or invalid' in e for e in prepare(self.root, self.directory)[2]))

    def test_argument_and_brand_changes_are_rejected(self):
        for value, expected in [('Envoyer %d sur Bitcoin', 'format argument'), ('Envoyer %@ sur BitCoin', 'brand or network')]:
            self.write('fr', {**self.fr, 'Localizable/send': value})
            self.assertTrue(any(expected in e for e in prepare(self.root, self.directory)[2]))

    def test_existing_catalog_english_cannot_be_rewritten(self):
        self.write('en', {**self.rows, 'Localizable/send': 'Send a payment'})
        self.assertTrue(any('English source changed' in e for e in prepare(self.root, self.directory)[2]))

    def test_shared_spelling_requires_specific_review_reason(self):
        self.write('fr', {**self.fr, 'LanguageNames/language.english': 'English'})
        self.assertTrue(any('identical to English' in e for e in prepare(self.root, self.directory)[2]))
        self.write('fr', {**self.fr, 'LanguageNames/language.english': 'English'},
                   sharedSpellingReasons={'LanguageNames/language.english': 'Fixture for a reviewed proper-name spelling.'})
        self.assertEqual(prepare(self.root, self.directory)[2], [])


if __name__ == '__main__':
    unittest.main()
