"""Prevent backend fee-provider details from entering Send's user interface."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SEND = ROOT / "EVMWallet" / "Send"


class SendFeeProviderUITests(unittest.TestCase):
    def test_provider_disclosure_copy_is_not_referenced_by_swift_ui(self):
        forbidden = (
            "send.network_fee.provider.footer",
            "send.network_fee.provider.fallback.footer",
        )
        for path in sorted(SEND.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            with self.subTest(file=str(path.relative_to(SEND))):
                for marker in forbidden:
                    self.assertNotIn(marker, source)

    def test_review_does_not_store_a_provider_for_presentation(self):
        source = (SEND / "SendReviewScreen.swift").read_text(encoding="utf-8")
        self.assertNotIn("feeQuoteProvider", source)

    def test_fee_selection_never_renders_the_provider_identifier(self):
        source = (SEND / "SendNetworkFeeSelectionScreen.swift").read_text(
            encoding="utf-8"
        )
        start = source.index("private func presetSection")
        end = source.index("private func feeRow", start)
        self.assertNotIn("quote.provider", source[start:end])

    def test_submission_reference_is_never_rendered(self):
        for path in sorted((ROOT / "EVMWallet").rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            if "import SwiftUI" not in source:
                continue
            with self.subTest(file=str(path.relative_to(ROOT))):
                self.assertNotIn('"send.broadcast.error_code"', source)
                self.assertNotIn('"Submission Error Reference"', source)
        source = (SEND / "SendBroadcastScreen.swift").read_text(encoding="utf-8")
        self.assertNotIn("error.diagnosticCode", source)


if __name__ == "__main__":
    unittest.main()
