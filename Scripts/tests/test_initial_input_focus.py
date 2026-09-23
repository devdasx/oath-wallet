"""Keep initial focus limited to explicitly requested screens."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[2] / "Oath"

class InitialInputFocusInventoryTests(unittest.TestCase):
    def test_presentation_focus_is_limited_to_requested_screens(self):
        expected = {
            "Home/HomeCurrencyConverterSheet.swift", "Settings/CurrencyConverterView.swift",
            "Settings/BitcoinTransactionBroadcastView.swift", "Settings/MnemonicLastWordFinderView.swift",
            "ImportWalletCredentialView.swift", "PrivateKeyCredentialView.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherRecoveryImportScreen.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherPrivateKeyImportScreen.swift",
            "Send/SendBitcoinOPReturnScreen.swift",
            "ImportWalletRecoveryPassphraseScreen.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherImportPassphraseScreen.swift",
            "SettingsWalletCreationPassphraseScreen.swift",
            "OnboardingPhysicalEntropyPassphraseScreen.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherCreationPassphraseScreen.swift",
        }
        actual = {
            path.relative_to(APP).as_posix() for path in APP.rglob("*.swift")
            if ".walletFocusOnPresentation" in path.read_text()
        }
        self.assertEqual(actual, expected)

    def test_removed_search_and_scroll_focus_policies_are_not_reintroduced(self):
        for path in APP.rglob("*.swift"):
            code = path.read_text()
            with self.subTest(screen=path.name):
                self.assertNotIn("walletSearchFocusOnPresentation", code)
                self.assertNotIn("walletRevealInitialInput", code)
