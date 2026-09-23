"""Guard reset-introduction copy without invoking any destructive actions."""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCREEN = ROOT / "Oath" / "ResetAppIntroductionScreen.swift"
ENGLISH = ROOT / "Oath" / "en.lproj" / "Localizable.strings"


class ResetIntroductionCopyTests(unittest.TestCase):
    def test_portfolio_row_restores_its_existing_subtitle(self):
        source = SCREEN.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r'WalletDataRemovalRow\(\s*'
            r'title: "settings\.reset\.contents\.activity",\s*'
            r'detail: "settings\.reset\.contents\.activity\.detail",\s*'
            r'icon: \.activity\s*\)',
        )
        self.assertIn(
            '"settings.reset.contents.activity.detail" = '
            '"Balances, assets, transactions, contacts, and connected apps.";',
            ENGLISH.read_text(encoding="utf-8"),
        )

    def test_warning_is_localized_and_above_both_buttons(self):
        source = SCREEN.read_text(encoding="utf-8")
        actions = source.split("private var actionBar: some View {", 1)[1]
        actions = actions.split("@MainActor", 1)[0]
        warning = 'Text(verbatim: WalletLocalization.string("settings.reset.review.irreversible"))'
        self.assertEqual(source.count(warning), 1)
        self.assertLess(actions.index(warning), actions.index("PrimaryWalletButton("))
        self.assertLess(actions.index("PrimaryWalletButton("), actions.index("SecondaryWalletButton("))
        self.assertIn("actionBar", source.split(".safeAreaBar(edge: .bottom, spacing: 0)", 1)[1])
        self.assertNotIn("This action cannot be undone.", source)

    def test_warning_can_wrap_and_uses_the_existing_warning_color(self):
        source = SCREEN.read_text(encoding="utf-8")
        warning = source.split('Text(verbatim: WalletLocalization.string("settings.reset.review.irreversible"))', 1)[1]
        warning = warning.split("PrimaryWalletButton(", 1)[0]
        self.assertIn(".font(.footnote)", warning)
        self.assertIn(".foregroundStyle(WalletTheme.danger)", warning)
        self.assertIn(".multilineTextAlignment(.center)", warning)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", warning)

    def test_warning_has_one_short_english_source_value(self):
        values = re.findall(
            r'^"settings\.reset\.review\.irreversible"\s*=\s*"([^"]*)";',
            ENGLISH.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        self.assertEqual(values, ["This action cannot be undone."])


if __name__ == "__main__":
    unittest.main()
