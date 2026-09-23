"""Guard every Aperture text-entry site, complementing native keyboard tests.

Run with: python3 -m unittest discover -s Scripts/tests -p 'test_text_input_return.py'
No screenshots, simulator data, or wallet credentials are read.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "EVMWallet"
NON_CODE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', re.DOTALL)
INPUT = re.compile(r"\b(?:TextField|SecureField|TextEditor)\s*\(|\.searchable\s*\(")
NATIVE_INPUT = re.compile(r"\b(?:UITextField|UITextView|UISearchBar|UISearchTextField)\s*\(")
PASSPHRASE_SCREENS = {
    "ImportWalletRecoveryPassphraseScreen.swift",
    "Home/WalletSwitcherSetup/WalletSwitcherImportPassphraseScreen.swift",
    "SettingsWalletCreationPassphraseScreen.swift",
    "OnboardingPhysicalEntropyPassphraseScreen.swift",
    "Home/WalletSwitcherSetup/WalletSwitcherCreationPassphraseScreen.swift",
}
MODIFIER = re.compile(r"\s*\.([A-Za-z_]\w*)")


def code_only(source):
    return NON_CODE.sub(lambda match: "".join("\n" if c == "\n" else " " for c in match[0]), source)


def closing_delimiter(code, opening):
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for position in range(opening, len(code)):
        char = code[position]
        if char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
            if not stack:
                return position + 1
    raise AssertionError("Unbalanced Swift expression")


def input_modifiers(code, match):
    position = closing_delimiter(code, match.end() - 1)
    names = []
    while modifier := MODIFIER.match(code, position):
        names.append(modifier[1])
        position = modifier.end()
        while position < len(code) and code[position].isspace():
            position += 1
        if position < len(code) and code[position] == "(":
            position = closing_delimiter(code, position)
        while position < len(code) and code[position].isspace():
            position += 1
        if position < len(code) and code[position] == "{":
            position = closing_delimiter(code, position)
    return names


class TextInputReturnTests(unittest.TestCase):
    def test_every_text_field_secure_field_editor_and_search_uses_the_shared_policy(self):
        sites = 0
        for path in sorted(APP.rglob("*.swift")):
            code = code_only(path.read_text(encoding="utf-8"))
            for match in INPUT.finditer(code):
                sites += 1
                with self.subTest(file=str(path.relative_to(APP)), line=code.count("\n", 0, match.start()) + 1):
                    expected = ("walletTextInputSubmitAction"
                                if path.relative_to(APP).as_posix() in PASSPHRASE_SCREENS
                                else "walletTextInputDirection")
                    self.assertIn(expected, input_modifiers(code, match))
            if path.relative_to(APP).as_posix() in {"Receive/ReceiveDetailsContent.swift", "Components/WalletExactText.swift"}:
                # This is a selectable address label, never an editable field.
                self.assertRegex(code, r"\b\w+\.isEditable = false")
                self.assertEqual(len(NATIVE_INPUT.findall(code)), 1)
            else:
                self.assertIsNone(NATIVE_INPUT.search(code), f"Audit new UIKit input in {path}")
        self.assertGreater(sites, 30, "The inventory must include every flow, alert, and search field")

    def test_guard_does_not_borrow_the_next_fields_policy(self):
        code = 'TextField("first", text: $first)\nTextField("second", text: $second).walletTextInputDirection()'
        matches = list(INPUT.finditer(code))
        self.assertNotIn("walletTextInputDirection", input_modifiers(code, matches[0]))
        self.assertIn("walletTextInputDirection", input_modifiers(code, matches[1]))

    def test_return_actions_are_owned_only_by_the_explicit_input_policies(self):
        for path in sorted(APP.rglob("*.swift")):
            if path.name in {"WalletTextInputDirection.swift", "WalletTextInputSubmitAction.swift"}:
                continue
            source = path.read_text(encoding="utf-8")
            if path.name == "RecoveryPhraseInlineInput.swift":
                self.assertIn("WalletTextInputReturnKey.preserveInputReturnHandling(on: field)", source)
                continue
            code = code_only(source)
            with self.subTest(file=str(path.relative_to(APP))):
                self.assertNotRegex(code, r"\.onSubmit\b|\.submitLabel\b")

    def test_root_covers_native_search_and_alert_fields(self):
        root = (APP / "EVMWalletApp.swift").read_text(encoding="utf-8")
        policy = (APP / "WalletTextInputReturnKey.swift").read_text(encoding="utf-8")
        self.assertIn(".walletTextInputConfiguration(appLayoutDirection)", root)
        for notification in (
            "UITextField.textDidBeginEditingNotification", "UITextField.textDidChangeNotification",
            "UITextView.textDidBeginEditingNotification", "UITextView.textDidChangeNotification",
        ):
            self.assertIn(notification, policy)

    def test_keyboard_ui_tests_do_not_capture_screenshots(self):
        spec = (ROOT / "Scripts/KeyboardReturnUITests/project.yml").read_text(encoding="utf-8")
        self.assertIn("captureScreenshotsAutomatically: false", spec)
        for path in (ROOT / "Scripts/KeyboardReturnUITests").rglob("*.swift"):
            code = code_only(path.read_text(encoding="utf-8"))
            self.assertNotRegex(code, r"\.screenshot\s*\(|XCTAttachment\s*\(")


if __name__ == "__main__":
    unittest.main()
