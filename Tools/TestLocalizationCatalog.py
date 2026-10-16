#!/usr/bin/env python3
"""Focused regression tests for the offline catalog guard; host-only."""
import json
from pathlib import Path
import tempfile
import unittest
from CheckLocalizationCatalog import audit_catalog, placeholders, source_keys
from GenerateLanguageCatalog import generate


def fixture(source="Send %@", translated="Envoyer %@"):
    return {"sourceLanguage": "en", "strings": {"send": {"localizations": {
        "en": {"stringUnit": {"state": "translated", "value": source}},
        "fr": {"stringUnit": {"state": "translated", "value": translated}},
    }}}}


class CatalogAuditTests(unittest.TestCase):
    def check(self, catalog, shared=None):
        return audit_catalog("Localizable", catalog, {"en", "fr"}, shared)

    def test_complete_translation_passes(self):
        self.assertEqual(self.check(fixture()), [])

    def test_missing_locale_cannot_fall_back_silently(self):
        catalog = fixture()
        del catalog["strings"]["send"]["localizations"]["fr"]
        self.assertTrue(any("missing locales" in error for error in self.check(catalog)))

    def test_english_placeholder_fails_even_when_marked_translated(self):
        self.assertTrue(any("identical to English" in e for e in self.check(fixture(translated="Send %@"))))

    def test_invisible_or_spacing_changes_do_not_translate_english(self):
        for value in ("\u2066Send %@\u2069", "Send\u200e %@", "Send  %@", "Send\u200b %@", "Send\ufe0f %@"):
            self.assertTrue(any("identical to English" in e for e in self.check(fixture(translated=value))), repr(value))

    def test_invisible_only_copy_is_empty(self):
        for value in ("\u2066\u2069", "\u200e", "\u200b", "\ufe0f", " \u2060 "):
            self.assertTrue(any("empty value" in e for e in self.check(fixture("About", value))), repr(value))

    def test_review_state_fails(self):
        catalog = fixture()
        catalog["strings"]["send"]["localizations"]["fr"]["stringUnit"]["state"] = "needs_review"
        self.assertTrue(any("expected translated" in error for error in self.check(catalog)))

    def test_empty_and_missing_units_fail(self):
        for value in ({}, {"stringUnit": {"state": "translated", "value": " "}}):
            catalog = fixture()
            catalog["strings"]["send"]["localizations"]["fr"] = value
            self.assertTrue(self.check(catalog))

    def test_printf_reordering_preserves_argument_identity(self):
        self.assertEqual(placeholders("%@ %d %%"), placeholders("%2$d %1$@ %%"))
        self.assertNotEqual(placeholders("%@ %d"), placeholders("%d %@"))
        self.assertNotEqual(placeholders("%ld"), placeholders("%d"))
        self.assertNotEqual(placeholders("%@ %@"), placeholders("%@"))
        self.assertTrue(any("format argument mismatch" in e for e in self.check(fixture(translated="Envoyer %d"))))

    def test_links_preserve_destinations_and_multiplicity(self):
        original = "Read [Terms](https://oathwallet.org/terms)."
        self.assertEqual(self.check(fixture(original, "Lire les [conditions](https://oathwallet.org/terms).")), [])
        for value in ("Lire les conditions.", "Lire [ici](https://example.org/terms).", "Lire https://oathwallet.org/terms."):
            self.assertTrue(any("markdown link" in e for e in self.check(fixture(original, value))))

    def test_shared_crypto_term_requires_explicit_reason(self):
        catalog = fixture("Token", "Token")
        self.assertTrue(self.check(catalog))
        self.assertEqual(self.check(catalog, {"send": {"fr": "Established shared financial spelling."}}), [])
        self.assertTrue(self.check(catalog, {"send": {"fr": ""}}))

    def test_real_backup_folder_names_are_not_translated(self):
        original = "Open iCloud Drive › Oath Wallet › Wallet Backups."
        self.assertEqual(self.check(fixture(original, "Ouvrez iCloud Drive › Oath Wallet › Wallet Backups.")), [])
        changed = "Ouvrez iCloud Drive › Oath Wallet › Sauvegardes."
        self.assertTrue(any("backup folder path changed" in e for e in self.check(fixture(original, changed))))

    def test_network_and_app_names_stay_intact_in_translated_prose(self):
        source = "Use an XRP Ledger account with Oath."
        self.assertEqual(self.check(fixture(source, "Nutze mit Oath ein Konto im XRP Ledger.")), [])
        for value in ("Nutze mit Oath ein XRP-Ledger-Konto.",
                      "Nutze mit Eid ein Konto im XRP Ledger."):
            self.assertTrue(any("brand or network" in e for e in self.check(fixture(source, value))))
        # Native case endings preserve the canonical name itself.
        self.assertEqual(self.check(fixture("Save to iCloud.", "Tallenna iCloudiin.")), [])

    def test_invariant_brand_and_format_only_are_allowed(self):
        catalog = fixture("WalletConnect", "WalletConnect")
        catalog["strings"]["send"]["shouldTranslate"] = False
        del catalog["strings"]["send"]["localizations"]["fr"]
        self.assertEqual(self.check(catalog), [])
        self.assertEqual(self.check(fixture("+%@", "+%@")), [])

    def test_plural_units_are_audited(self):
        catalog = fixture("%@ items", "%@ éléments")
        catalog["strings"]["send"]["localizations"]["fr"] = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "%@ élément"}},
            "other": {"stringUnit": {"state": "needs_review", "value": "%@ éléments"}},
        }}}
        self.assertTrue(any("other" in e and "expected translated" in e for e in self.check(catalog)))

    def test_generator_does_not_seed_or_write_when_translation_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Design/Localization").mkdir(parents=True)
            (root / "OathApp/Resources").mkdir(parents=True)
            (root / "OathAtmosphere/Localization").mkdir(parents=True)
            registry = [{"code": code, "nameKey": "language." + code} for code in ("en", "fr")]
            (root / "Design/Localization/languages.json").write_text(json.dumps(registry))
            incomplete = fixture()
            del incomplete["strings"]["send"]["localizations"]["fr"]
            (root / "OathApp/Resources/Localizable.xcstrings").write_text(json.dumps(incomplete))
            (root / "OathApp/Resources/InfoPlist.xcstrings").write_text(json.dumps({"sourceLanguage": "en", "strings": {}}))
            names = fixture()
            names["strings"]["language.en"] = names["strings"].pop("send")
            names["strings"]["language.fr"] = names["strings"]["language.en"]
            (root / "OathApp/Resources/LanguageNames.xcstrings").write_text(json.dumps(names))
            before = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            with self.assertRaisesRegex(ValueError, "before writing"):
                generate(root)
            self.assertEqual(before, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            self.assertFalse((root / "OathAtmosphere/Localization/OathLanguageCatalog.swift").exists())

    def test_source_key_coverage_handles_implicit_and_explicit_cases(self):
        self.assertEqual(source_keys('enum Keys {\n case send, receive\n case balance = "wallet.balance"\n}'), {"send", "receive", "wallet.balance"})


    def test_rtl_catalog_may_add_balanced_directional_isolation(self):
        self.assertEqual(self.check(fixture('iCloud backup', '\u2066iCloud\u2069 sauvegarde')), [])
        self.assertTrue(any('bidirectional' in e for e in self.check(fixture('Backup', '\u202eSauvegarde'))))
        self.assertTrue(any('unbalanced' in e for e in self.check(fixture('Backup', '\u2066Sauvegarde'))))

    def test_language_names_need_reviewed_shared_spelling_reasons(self):
        catalog = fixture('English', 'English')
        self.assertTrue(any('identical to English' in e for e in audit_catalog('LanguageNames', catalog, {'en', 'fr'})))
        self.assertEqual(audit_catalog('LanguageNames', catalog, {'en', 'fr'}, {'send': {'fr': 'Established borrowed language name.'}}), [])


if __name__ == "__main__":
    unittest.main()
