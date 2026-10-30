#!/usr/bin/env python3
"""Host-only checks of production Home presentation. Synthetic balances only."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# The host builder cannot mount UIKit views. Check the production input wiring
# as well, so a device-locale regression cannot pass formatter-only tests.
home = (root / "OathAtmosphere/Home/OathHomeScreen.swift").read_text()
session = (root / "OathAtmosphere/Wallet/OathWalletSession.swift").read_text()
fallback = home.split("private var totalBalance: String {", 1)[1].split("private var summary:", 1)[0]
startup = session.split("private func prepareHomeDisplaySnapshot(", 1)[1].split("let prepared =", 1)[0]
assert "locale: strings.language.locale" in fallback and ".autoupdatingCurrent" not in fallback
assert "formattingLocale: strings.language.locale.identifier" in home
assert 'snapshot.settings["language"]' in startup and "preference.resolve().locale.identifier" in startup
assert "formattingLocale: locale, sortingLocale: locale" in startup
assert "formattingLocale: Locale.autoupdatingCurrent" not in home + session
with tempfile.TemporaryDirectory(prefix="oath-home-portfolio-") as temporary:
    work = Path(temporary)
    source = work / "Sources/HomeChecks"
    source.mkdir(parents=True)
    for file in ["Home/OathHomePortfolioModel.swift", "Home/OathAssetAmountFormat.swift",
                 "Import/OathImportCatalog.swift", "Localization/OathLocalization.swift",
                 "Localization/OathLanguageCatalog.swift", "Localization/OathStringKey.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    shutil.copyfile(root / "Tools/CheckHomePortfolio.swift", source / "CheckHomePortfolio.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "HomeChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "HomeChecks", dependencies: ["OathDatabase", "OathDiagnostics"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathDiagnostics"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-home-portfolio-host-build",
                    "--build-system", "native", "HomeChecks"], check=True)
