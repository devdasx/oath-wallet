#!/usr/bin/env python3
"""Run all production send models with local service/session fixtures on macOS.

No app, simulator, device, keys or network requests. Production model methods
are copied unchanged; service boundaries provide deterministic quote/submit results.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
chains = ['Bitcoin', 'EVM', 'Arc', 'Sui', 'Xrpl', 'Stellar', 'Tron', 'Ton', 'Solana', 'Aptos', 'Thorchain', 'Near', 'Polkadot']
with tempfile.TemporaryDirectory(prefix='oath-receipt-lifecycle-') as temporary:
    work = Path(temporary)
    sources = work / 'Sources/ReceiptChecks'
    sources.mkdir(parents=True)
    for chain in chains:
        name = f'Oath{chain}SendModel.swift'
        shutil.copyfile(root / 'OathAtmosphere/Send' / name, sources / name)
    shutil.copyfile(root / 'OathAtmosphere/Localization/OathStringKey.swift', sources / 'OathStringKey.swift')
    shutil.copyfile(root / 'Tools/CheckSendReceiptLifecycle.swift', sources / 'CheckSendReceiptLifecycle.swift')
    services = ['import Foundation\nimport OathAnkr\nimport OathBitcoin\n']
    conformances = []
    for chain in chains:
        text = (root / f'OathAtmosphere/Send/Oath{chain}SendService.swift').read_text()
        signature = re.search(r'    func quote\([^\{]+?async throws -> Oath\w+Quote \{', text).group(0)
        services.append(f'typealias Oath{chain}Quote = FixtureQuote\n')
        services.append(f'''actor Oath{chain}SendService {{
    static let shared = Oath{chain}SendService()
    static func service(for network: UTXONetwork) throws -> Oath{chain}SendService {{ shared }}
{signature}
        try await FixtureControl.shared.quote()
    }}
    func submit(_ quote: FixtureQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {{
        try await FixtureControl.shared.submit()
    }}
}}
''')
        prepare = 'prepare(model: model, session: session, forceRefresh: false)' if chain == 'Bitcoin' else 'prepare(model: model, session: session)'
        conformances.append(f'''extension Oath{chain}SendModel: ReceiptModel {{
    func prepareFixture(_ model: OathSendModel, session: OathWalletSession) {{ {prepare} }}
}}
''')
    (sources / 'Services.swift').write_text(''.join(services))
    (sources / 'Conformances.swift').write_text(''.join(conformances) + '\n@MainActor func models() -> [(String, any ReceiptModel)] { [\n' + ',\n'.join(f'("{c}", Oath{c}SendModel())' for c in chains) + '\n] }\n')
    packages = ['OathAnkr', 'OathBitcoin', 'OathDiagnostics']
    deps = ', '.join('.package(path: %s)' % json.dumps(str(root / 'Packages' / p)) for p in packages)
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReceiptChecks", platforms: [.macOS("15.5")],
    dependencies: [%s], targets: [.executableTarget(name: "ReceiptChecks", dependencies: [%s])], swiftLanguageModes: [.v6])
''' % (deps, ', '.join(json.dumps(p) for p in packages)))
    subprocess.run(['swift', 'run', '--build-system', 'native', '--package-path', str(work), '--scratch-path', '/tmp/oath-receipt-lifecycle-host', 'ReceiptChecks'], check=True)
