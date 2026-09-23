from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "validate_infoplist_localizations.py"
)
SPEC = importlib.util.spec_from_file_location(
    "validate_infoplist_localizations",
    SCRIPT_PATH,
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InfoPlistLocalizationValidationTests(unittest.TestCase):
    def test_numbered_arguments_can_follow_natural_translation_order(self) -> None:
        self.assertEqual(MODULE.format_arguments('%@ %d %@'),
                         MODULE.format_arguments('%3$@ %1$@ %2$d'))
        self.assertNotEqual(MODULE.format_arguments('%@ %d'),
                            MODULE.format_arguments('%1$d %2$@'))
        self.assertNotEqual(MODULE.format_arguments('%@ %@'),
                            MODULE.format_arguments('%1$@ %1$@'))
        self.assertNotEqual(MODULE.format_arguments('%@ %@'),
                            MODULE.format_arguments('%2$@ %@'))
        self.assertEqual(MODULE.format_arguments('100%% %@'),
                         MODULE.format_arguments('%1$@ 100%%'))

    def test_known_semantic_errors_are_rejected_only_in_their_reviewed_context(self) -> None:
        for (locale, key, english), mistranslation in MODULE.CONTEXTUAL_TRANSLATION_ERRORS.items():
            with self.subTest(locale=locale, key=key):
                self.assertEqual(
                    MODULE.translation_defect(locale, key, english, mistranslation),
                    "uses a known mistranslation for this screen context",
                )
        self.assertIsNone(MODULE.translation_defect(
            "de", "onboarding.entropy.example", "Physical balance", "Gleichgewicht"
        ))
        self.assertIsNone(MODULE.translation_defect(
            "ar", "bitcoin.settings.balance", "Balance", "الرصيد"
        ))

    def test_descriptive_network_names_are_not_exempt_by_prefix(self) -> None:
        for key, value in (
            ("network.sui.name", "Sui Network"),
            ("network.future.name", "Choose a Network"),
            ("asset.future.error", "Asset Not Available"),
            ("network.bitcoin.name", "Bitcoin Network"),
            ("send.amount.unselected_placeholder", "Enter 0.00"),
        ):
            with self.subTest(key=key):
                self.assertIsNotNone(MODULE.translation_defect("ja", key, value, value))
        self.assertIsNone(MODULE.translation_defect("ja", "network.bitcoin.name", "Bitcoin", "Bitcoin"))

    def test_former_invariants_require_complete_translations(self) -> None:
        for key, english, old in (
            ("notification.generic.title", "Aperture Notification", "Aperture"),
            ("onboarding.carousel.open_source.visual.repository.path", "View github.com/devdasx/aperture", "github.com/devdasx/aperture"),
            ("wallet.activity.filter.amount.placeholder", "Enter 0.00", "0"),
        ):
            with self.subTest(key=key):
                self.assertIsNotNone(MODULE.translation_defect("ml", key, english, old))
                self.assertIsNotNone(MODULE.translation_defect("ml", key, english, english))

    def test_shared_spellings_are_scoped_to_language_key_and_value(self) -> None:
        key = "settings.about.version.value"
        self.assertIsNone(MODULE.translation_defect("fr", key, "Version 2.40.08", "Version 2.40.08"))
        self.assertIsNotNone(MODULE.translation_defect("ja", key, "Version 2.40.08", "Version 2.40.08"))
        self.assertIsNotNone(MODULE.translation_defect("fr", key, "Latest Version", "Latest Version"))
        self.assertIsNotNone(MODULE.translation_defect("fr", "example.version", "Version 2.40.08", "Version 2.40.08"))

    def test_bitcoin_transaction_shared_spelling_is_french_and_context_specific(self) -> None:
        key = "bitcoin.settings.silent.transaction.section"
        self.assertIsNone(MODULE.translation_defect("fr", key, "Transaction", "Transaction"))
        self.assertIsNotNone(MODULE.translation_defect("ar", key, "Transaction", "Transaction"))
        self.assertIsNotNone(MODULE.translation_defect("fr", key, "Transaction Details", "Transaction Details"))
        key = "receive.bitcoin.address_type.silent_payments"
        self.assertIsNotNone(MODULE.translation_defect("ar", key, "Silent Payments", "Silent Payments"))

    def test_fee_placeholder_preserves_accepted_decimal_format(self) -> None:
        key = "send.network_fee.custom.integer.placeholder"
        for invalid in ("0", "0,00", "00.0"):
            with self.subTest(value=invalid):
                self.assertIsNotNone(MODULE.translation_defect("hr", key, "0.00", invalid))
        self.assertIsNone(MODULE.translation_defect("hr", key, "0.00", "0.00"))

    def test_hardcoded_copy_in_swiftui_and_uikit_bridges_is_detected(self) -> None:
        source = '''
        Text("Welcome Back")
        Text(verbatim: "Transfer Ready")
        field.placeholder = "Enter Amount"
        label.text = "No Transactions"
        button.setTitle("Send Again", for: .normal)
        UIAlertAction(title: "Copy Address", style: .default)
        LocalizedStringResource("Import Wallet")
        Text("wallet.home.title")
        label.text = WalletLocalization.string("wallet.home.title")
        let resource = LocalizedStringResource("intent.search.title", defaultValue: "Search Wallet")
        let protocolIdentifier = "OP_RETURN"
        '''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Screen.swift").write_text(source)
            with patch.object(MODULE, "APP_DIRECTORY", root):
                literals = {value for _, _, value in MODULE.hardcoded_swift_ui_literals()}
        self.assertEqual(literals, {
            "Welcome Back", "Transfer Ready", "Enter Amount", "No Transactions",
            "Send Again", "Copy Address", "Import Wallet",
        })

    def test_compact_entropy_count_accepts_shared_unit_only(self) -> None:
        key = "wallet.creation.entropy.progress.value"
        compact = "%1$d/%2$d bits"
        old = "%1$d of %2$d Entropy Bits Collected"
        for locale in ("es", "fr", "nl", "pt-BR", "pt-PT"):
            with self.subTest(locale=locale):
                self.assertIsNone(
                    MODULE.translation_defect(locale, key, compact, compact)
                )
                self.assertIsNotNone(
                    MODULE.translation_defect(locale, key, compact, old)
                )
                self.assertIsNotNone(
                    MODULE.translation_defect(locale, key, old, old)
                )
        self.assertIsNotNone(
            MODULE.translation_defect("ar", key, compact, compact)
        )
        self.assertIsNotNone(
            MODULE.translation_defect("fr", "example.message", compact, compact)
        )

    def test_parenthesized_asset_tickers_are_not_duplicate_words(self) -> None:
        for value in ("Gram (GRAM)", "Sui (SUI)"):
            with self.subTest(value=value):
                self.assertEqual(
                    MODULE.structural_translation_defects(
                        "fr",
                        "asset.display_name",
                        value,
                    ),
                    [],
                )

        self.assertEqual(
            MODULE.structural_translation_defects(
                "fr",
                "example.message",
                "word word",
            ),
            ["repeats adjacent word 'word'"],
        )

    def test_breadcrumbs_are_not_malformed_translation_markers(self) -> None:
        self.assertIsNone(
            MODULE.translation_defect(
                "fr",
                "example.breadcrumb",
                "Transfer all application data",
                "Settings > Security > Transfer All App Data",
            )
        )
        self.assertEqual(
            MODULE.translation_defect(
                "fr",
                "example.message",
                "Transfer all application data",
                "tl>Transfer All App Data",
            ),
            "contains a malformed translation marker",
        )

    def test_internal_localization_markers_are_rejected(self) -> None:
        self.assertEqual(
            MODULE.translation_defect(
                "yo",
                "example.message",
                "Remove local wallet data.",
                "Yọ data agbegbe kuro. _CODEX_KEY_4__",
            ),
            "contains an internal localization marker",
        )

    def test_exact_english_source_values_are_rejected(self) -> None:
        self.assertEqual(
            MODULE.translation_defect(
                "fil",
                "wallet.private_key.title",
                "Private Key",
                "Private Key",
            ),
            "still uses the English source value",
        )

    def test_technical_names_do_not_exempt_descriptive_labels(self) -> None:
        examples = {
            "settings.currency.current": "US Dollar (USD)",
            "receive.solana.path.phantom": "Phantom Derivation Path",
            "receive.solana.path.trust_wallet": "Trust Wallet Derivation Path",
            "settings.wallets.private_key.export.chain.solana.phantom": "Solana — Phantom Path",
            "settings.wallets.private_key.export.chain.solana.trust_wallet": "Solana — Trust Wallet Path",
            "send.network_fee.rate.evm_legacy": "%1$@ Gwei Gas Price",
            "send.network_fee.rate.utxo": "%1$@ sat/vB Fee Rate",
        }
        for key, value in examples.items():
            with self.subTest(key=key):
                self.assertEqual(
                    MODULE.translation_defect("fil", key, value, value),
                    "still uses the English source value",
                )
        self.assertIsNone(MODULE.translation_defect(
            "fil", "send.network_fee.rate.utxo", "%1$@ sat/vB Fee Rate",
            "Rate ng Bayarin: %1$@ sat/vB",
        ))
        self.assertIsNone(MODULE.translation_defect(
            "fil", "example.fee_unit", "%1$@ sat/vB", "%1$@ sat/vB",
        ))

    def test_shortcuts_require_every_locale_and_preserve_app_name(self) -> None:
        phrase = "Search in ${applicationName}"
        catalog = {
            "sourceLanguage": "en",
            "strings": {phrase: {"localizations": {
                "en": {"stringUnit": {"state": "translated", "value": phrase}},
                "ar": {"stringUnit": {"state": "translated", "value": "ابحث في ${applicationName}"}},
            }}},
        }
        self.assertEqual(MODULE.shortcut_catalog_defects(catalog, {"en", "ar"}, {phrase}), [])
        unit = catalog["strings"][phrase]["localizations"]["ar"]["stringUnit"]
        for value, state, expected in [
            ("", "translated", "missing shortcut translation"),
            ("ابحث", "translated", "changes phrase placeholders"),
            (phrase, "translated", "still uses English"),
            ("ابحث في ${applicationName}", "needs_review", "not marked translated"),
        ]:
            with self.subTest(value=value, state=state):
                unit.update(value=value, state=state)
                errors = MODULE.shortcut_catalog_defects(catalog, {"en", "ar"}, {phrase})
                self.assertTrue(any(expected in error for error in errors), errors)
        unit.update(value="ابحث في ${applicationName}", state="translated")
        errors = MODULE.shortcut_catalog_defects(catalog, {"en", "ar", "fr"}, {phrase})
        self.assertTrue(any("fr is missing" in error for error in errors))
        errors = MODULE.shortcut_catalog_defects(catalog, {"en", "ar"}, {phrase, "Another phrase"})
        self.assertTrue(any("missing source phrase" in error for error in errors))

    def test_transfer_instructions_reference_translated_current_menu_labels(self) -> None:
        values = {
            "settings.title": "Einstellungen",
            "settings.security.title": "Sicherheit",
            "device_migration.security.action": "Sichere Übertragung starten",
            "device_migration.import.option.title": "Von einem anderen iPhone übertragen",
            "device_migration.scan.instruction": "Einstellungen > Sicherheit > Sichere Übertragung starten",
            "device_migration.status.waiting.detail": "Von einem anderen iPhone übertragen",
        }
        self.assertEqual(MODULE.menu_label_reference_defects(values), [])
        values["device_migration.scan.instruction"] = "Settings > Security > Transfer All App Data"
        self.assertEqual(len(MODULE.menu_label_reference_defects(values)), 3)
        values["device_migration.scan.instruction"] = "Einstellungen > Sicherheit > Alle App-Daten übertragen"
        self.assertEqual(len(MODULE.menu_label_reference_defects(values)), 1)

    def test_obsolete_unit_only_fee_values_are_rejected(self) -> None:
        self.assertEqual(MODULE.translation_defect(
            "sw", "send.network_fee.rate.utxo", "%1$@ sat/vB Fee Rate", "%1$@ sat/vB",
        ), "still uses an obsolete English source value")
        self.assertIsNone(MODULE.translation_defect(
            "sw", "send.network_fee.rate.utxo", "%1$@ sat/vB Fee Rate",
            "Kiwango cha ada: %1$@ sat/vB",
        ))

    def test_justified_exact_values_remain_allowed(self) -> None:
        self.assertIsNone(
            MODULE.translation_defect(
                "es",
                "accessibility.error.format",
                "Error: %@",
                "Error: %@",
            )
        )
        self.assertIsNone(
            MODULE.translation_defect(
                "fil",
                "send.amount.zero",
                "0.00",
                "0.00",
            )
        )


if __name__ == "__main__":
    unittest.main()
