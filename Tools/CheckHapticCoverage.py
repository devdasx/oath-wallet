#!/usr/bin/env python3
"""Prevent new UI code from silently bypassing the app's haptic preference.

Interaction contract:
- Use OathButton/OathActionButton: native activation, including accessibility.
- Use OathClipboard or OathSensitiveClipboard for copy; explicit Paste reads
  through OathClipboard.paste(). Never inspect the clipboard on appearance.
- Emit success only after committed user work; error only for a presented error.
  Cancellations, background sync, price updates and view rendering stay silent.
- Use oathHapticFeedback for outcome revisions, never progress or text typing.
- Native switches/pickers, system keyboard, Face ID, menus and share controllers
  retain their OS feedback. Do not duplicate it or use private suppression APIs.
- New UIKit actions use OathHaptics.shared.perform; new app buttons must use
  the native Button factories. All custom hardware feedback goes through one
  preference-aware driver, so future screens inherit mute and coalescing.

This audits source integration, not tactile behavior on a physical iPhone.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
failures = []
buttons = 0
for folder in (root / "OathAtmosphere", root / "OathApp"):
    for path in folder.rglob("*.swift"):
        if path.name.startswith("._"):
            continue
        source = path.read_text()
        code = re.sub(r"//[^\n]*", "", source)
        buttons += len(re.findall(r"\bOath(?:Action)?Button\s*[({]", code))
        if path.name != "OathFeedbackControls.swift" and re.search(r"\bButton\s*[({]", code):
            failures.append(f"{path.relative_to(root)}: native Button activation bypasses the shared factory")
        if path.name != "OathHaptics.swift" and re.search(r"UI(?:Impact|Notification|Selection)FeedbackGenerator|\.sensoryFeedback\(|CHHapticEngine|AudioServicesPlaySystemSound", code):
            failures.append(f"{path.relative_to(root)}: hardware feedback bypasses the preference")
        if path.name != "OathSensitiveClipboard.swift" and "UIPasteboard.general" in code:
            failures.append(f"{path.relative_to(root)}: clipboard action bypasses shared outcome feedback")
assert not failures, "\n".join(failures)
print(f"Haptic integration audit passed: {buttons} shared native-button/action sites; no direct feedback or clipboard bypasses.")
