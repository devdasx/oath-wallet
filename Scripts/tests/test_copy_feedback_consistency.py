"""Guard explicit clipboard feedback outside the intentionally unchanged Receive flow."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Oath"
ENGLISH = APP / "en.lproj" / "Localizable.strings"
WRITE_MARKERS = (
    "UIPasteboard.general.setItems(",
    "SendTransactionIdentityClipboard.copy(",
)


def is_receive_screen(path: Path) -> bool:
    return "Receive" in path.parts or path.name in {
        "ReceiveWalletView.swift",
        "SelectedAssetReceiveScreen.swift",
    }


class CopyFeedbackConsistencyTests(unittest.TestCase):
    def test_non_receive_copy_writes_use_shared_temporary_feedback(self):
        copy_surfaces = []
        for path in sorted(APP.rglob("*.swift")):
            if is_receive_screen(path):
                continue
            source = path.read_text(encoding="utf-8")
            if not any(marker in source for marker in WRITE_MARKERS):
                continue
            copy_surfaces.append(path.relative_to(APP))
            with self.subTest(file=str(path.relative_to(APP))):
                self.assertIn("WalletClipboardCopyFeedback", source)
                self.assertIn("copyFeedback.markCopied()", source)

        self.assertEqual(len(copy_surfaces), 8)

    def test_non_receive_surfaces_do_not_reuse_receive_copy_wording(self):
        for path in sorted(APP.rglob("*.swift")):
            if is_receive_screen(path):
                continue
            source = path.read_text(encoding="utf-8")
            with self.subTest(file=str(path.relative_to(APP))):
                self.assertNotIn('"receive.action.copy"', source)
                self.assertNotIn('"receive.action.copied"', source)

    def test_english_wording_is_standardized_but_receive_stays_unchanged(self):
        source = ENGLISH.read_text(encoding="utf-8")
        expected = (
            '"wallet.creation.recovery.copy_to_clipboard" = "Copy to Clipboard";',
            '"wallet.creation.recovery.copied_to_clipboard" = "Copied to Clipboard";',
            '"wallet.transaction.details.copy_transaction_id" = "Copy to Clipboard";',
            '"receive.action.copy" = "Copy";',
            '"receive.action.copied" = "Copied";',
        )
        for entry in expected:
            self.assertIn(entry, source)

    def test_shared_feedback_duration_is_exactly_two_seconds(self):
        source = (APP / "WalletRecoveryPhraseCopyState.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("static let displayDuration: Duration = .seconds(2)", source)


if __name__ == "__main__":
    unittest.main()
