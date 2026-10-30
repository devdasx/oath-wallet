#!/usr/bin/env python3
"""Host regression tests of production policy and the app's Reown SDK.

No app, simulator, device, wallet storage, relay or transaction access. Requires
the app's resolved Reown 2.4.0 checkout in OATH_REOWN_CHECKOUT. Namespace sources
are tested unchanged. A temporary SDK copy guards its two iOS-only link-opening
calls (upstream's macOS target lacks these guards); either call fails the test.
The app's dependency checkout is never modified. Requires @walletconnect/utils
in NODE_PATH for the independent browser permission check.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-wc-namespaces-") as folder:
    work = Path(folder)
    sources = work / "Tests/NamespaceChecks"
    sources.mkdir(parents=True)
    shutil.copyfile(root / "OathAtmosphere/Scanner/OathWalletConnectPolicy.swift", sources / "Policy.swift")
    shutil.copyfile(root / "Tools/CheckWalletConnectNamespaces.swift", sources / "Checks.swift")
    checkout = Path(os.environ["OATH_REOWN_CHECKOUT"])
    host_sdk = work / "Reown"
    host_sdk.mkdir()
    manifest = (checkout / "Package.swift").read_text().replace('.package(path: "../../Packages/OathDiagnostics")', '.package(path: ' + json.dumps(str(root / "Packages/OathDiagnostics")) + ')')
    (host_sdk / "Package.swift").write_text(manifest)
    shutil.copytree(checkout / "Sources", host_sdk / "Sources")
    link = host_sdk / "Sources/WalletConnectSign/Auth/Link/LinkEnvelopesDispatcher.swift"
    code = link.read_text()
    link.chmod(0o600)
    platform_call = "UIApplication.shared.open(envelopeUrl, options: [.universalLinksOnly: true]) { success in"
    assert code.count(platform_call) == 2, "Review upstream host compatibility before running"
    link.write_text("import Foundation\n" + code.replace(platform_call, "unavailableHostLinkOpen { success in") + '''
private func unavailableHostLinkOpen(completion: (Bool) -> Void) {
    preconditionFailure("Link opening is outside namespace host tests")
}
''')
    sdk = '.package(name: "Reown", path: %s)' % json.dumps(str(host_sdk))
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "NamespaceChecks", platforms: [.macOS(.v14)],
    dependencies: [%s, .package(path: %s)],
    targets: [.testTarget(name: "NamespaceChecks", dependencies: [
        .product(name: "WalletConnect", package: "Reown"), "OathAnkr"
    ])], swiftLanguageModes: [.v6])
''' % (sdk, json.dumps(str(root / "Packages/OathAnkr"))))
    fixture = work / "namespaces.json"
    env = os.environ.copy()
    env["OATH_NAMESPACE_FIXTURE"] = str(fixture)
    subprocess.run(["swift", "test", "--build-system", "native", "--package-path", str(work),
                    "--scratch-path", "/tmp/oath-wc-namespace-host-build",
                    "--filter", "WalletConnectNamespaceTests"], check=True, env=env)
    subprocess.run(["node", str(root / "Tools/CheckWalletConnectNamespaces.cjs"), str(fixture)], check=True)
