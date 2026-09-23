"""Guard wallet-removal presentation without triggering backup or deletion."""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCREEN = ROOT / "EVMWallet/WalletManagement/RemoveWalletIntroductionScreen.swift"
ENGLISH = ROOT / "EVMWallet/en.lproj/Localizable.strings"


class RemoveWalletIntroductionCopyTests(unittest.TestCase):
    def test_portfolio_restores_the_existing_wallet_specific_subtitle(self):
        source = SCREEN.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r'WalletDataRemovalRow\(\s*'
            r'title: "settings\.wallets\.remove\.contents\.activity\.title",\s*'
            r'detail: "settings\.wallets\.remove\.contents\.activity",\s*'
            r'icon: \.activity\s*\)',
        )
        self.assertIn(
            '"settings.wallets.remove.contents.activity" = '
            '"Assets and transaction history associated with this wallet";',
            ENGLISH.read_text(encoding="utf-8"),
        )

    def test_wallet_settings_row_is_not_rendered(self):
        source = SCREEN.read_text(encoding="utf-8")
        self.assertNotIn('"settings.wallets.remove.contents.settings.title"', source)
        self.assertNotIn('"settings.wallets.remove.contents.settings"', source)
        self.assertIn('"settings.wallets.remove.contents.accounts.title"', source)
        self.assertIn('"settings.wallets.remove.contents.recovery_phrase.title"', source)
        self.assertIn('"settings.wallets.remove.contents.private_key.title"', source)

    def test_icloud_footer_has_only_the_requested_short_copy(self):
        values = re.findall(
            r'^"settings\.wallets\.remove\.icloud_preserved\.footer"\s*=\s*"([^"]*)";',
            ENGLISH.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        self.assertEqual(values, ["Each wallet uses its own Apple Passkey."])

    def test_short_footer_is_scoped_to_removal_with_localization_fallback(self):
        source = SCREEN.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r'footer: \{\s*if shouldOfferICloudBackup \{\s*'
            r'Text\(verbatim: WalletLocalization\.string\(\s*'
            r'"settings\.wallets\.remove\.icloud_preserved\.footer"\s*\)\)',
        )
        self.assertNotIn('"settings.wallets.backup.keychain.footer"', source)
        self.assertNotIn("Each wallet uses its own Apple Passkey.", source)


if __name__ == "__main__":
    unittest.main()
