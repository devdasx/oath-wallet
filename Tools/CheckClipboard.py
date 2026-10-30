#!/usr/bin/env python3
"""Run the real clipboard helpers against an in-memory UIKit boundary on macOS.

Never accesses the host pasteboard, credentials, a simulator or a device.
This checks app policy, not delivery by Apple's cross-device services.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
clipboard = root / "OathAtmosphere/Shared/OathSensitiveClipboard.swift"

# Every explicit app copy must pass through a reviewed clipboard policy.
for folder in (root / "OathAtmosphere", root / "OathApp", root / "Packages"):
    for path in folder.rglob("*.swift"):
        if path == clipboard or path.name.startswith("._") or any(part in path.parts for part in (".build", "Tests")):
            continue
        source = path.read_text()
        assert "UIPasteboard" not in source and "NSPasteboard" not in source, (
            f"Clipboard policy bypass in {path.relative_to(root)}"
        )

source = clipboard.read_text()
# Secrets must never be routed through the public cross-device copy helper.
for name in ("OathRecoveryPhrasePages.swift", "OathPrivateKeyPages.swift"):
    screen = (root / "OathAtmosphere/Home" / name).read_text()
    assert "OathSensitiveClipboard.copy(" in screen, f"Missing secret-copy policy: {name}"
    assert "OathClipboard.copy(" not in screen, f"Public-copy policy used on secret screen: {name}"
assert "clearIfOwned" not in source, "Use system expiry rather than a timer that could clear a newer copy"
assert "general.items =" not in source and "general.string =" not in source
reset = (root / "OathAtmosphere/Wallet/OathResetEnvironment.swift").read_text()
assert "Clipboard" not in reset and "Pasteboard" not in reset, "Reset must leave the clipboard alone"

with tempfile.TemporaryDirectory(prefix="oath-clipboard-check-") as temporary:
    work = Path(temporary)
    stub = work / "UIKit.swift"
    stub.write_text('''
@_exported import Foundation

@MainActor public final class UIPasteboard {
    public struct OptionsKey: Hashable, Sendable {
        public static let localOnly = Self(rawValue: "localOnly")
        public static let expirationDate = Self(rawValue: "expirationDate")
        let rawValue: String
    }
    public static let general = UIPasteboard()
    public static let typeAutomatic = "automatic-text"
    public var items: [[String: Any]] = []
    public private(set) var options: [OptionsKey: Any] = [:]
    public private(set) var writes = 0
    public private(set) var reads = 0
    public var string: String? {
        reads += 1
        return items.first?[Self.typeAutomatic] as? String
    }
    public func setItems(_ items: [[String: Any]], options: [OptionsKey: Any]) {
        self.items = items
        self.options = options
        writes += 1
    }
    public func contains(pasteboardTypes: [String]) -> Bool {
        items.contains { item in pasteboardTypes.contains { item[$0] != nil } }
    }
}
''')
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-emit-module", "-emit-library",
        "-module-name", "UIKit", str(stub), "-o", str(work / "libUIKit.dylib"),
        "-emit-module-path", str(work / "UIKit.swiftmodule"),
    ], check=True)
    executable = work / "CheckClipboard"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        "-I", str(work), "-L", str(work), "-lUIKit",
        "-Xlinker", "-rpath", "-Xlinker", str(work),
        str(clipboard), str(root / "Tools/CheckClipboard.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
print("App clipboard coverage passed: all explicit writes use the shared helpers.")
