#!/usr/bin/env python3
"""Run production price routing on macOS, without an app/simulator launch.

Only app model/catalog wiring and the router's GRDB health persistence are
substituted. HTTP parsing, decimal decoding, provider selection, adaptive
ranking/deadlines and token stages compile directly from production sources.
The migration's actual SQL is tested separately against an in-memory database.
"""
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def without_body(source, signature):
    start = source.index(signature)
    begin = source.index('{', start)
    depth = 1
    end = begin + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[:begin] + '{}' + source[end:]


def migration_test():
    source = (ROOT / 'EVMWallet/Persistence/WalletTokenDEXPriceMigration.swift').read_text()
    sql = source.split('sql: """', 1)[1].split('"""', 1)[0]
    db = sqlite3.connect(':memory:')
    db.executescript('''
        CREATE TABLE assets(id TEXT, assetType TEXT);
        INSERT INTO assets VALUES ('base:token', 'fungibleToken'), ('base:native', 'native');
        CREATE TABLE assetPrices(assetID TEXT, price TEXT);
        INSERT INTO assetPrices VALUES ('base:token', '0.03556'), ('base:native', '2300');
    ''')
    for table in ['accountAssets', 'transactions', 'transactionTransfers']:
        db.execute(f'CREATE TABLE {table}(assetID TEXT, fiatUSDValue TEXT, amount TEXT, note TEXT)')
        db.executemany(f'INSERT INTO {table} VALUES (?, ?, ?, ?)', [
            ('base:token', '4929445140.85', '138295198634.16446765731119248', 'keep'),
            ('base:native', '2300', '1', 'keep')])
    db.executescript(sql)
    db.executescript(sql)
    assert db.execute('SELECT * FROM assetPrices').fetchall() == [('base:native', '2300')]
    for table in ['accountAssets', 'transactions', 'transactionTransfers']:
        assert db.execute(f'SELECT * FROM {table}').fetchall() == [
            ('base:token', None, '138295198634.16446765731119248', 'keep'),
            ('base:native', '2300', '1', 'keep')]
    print('PASS: migration clears only token-derived values and preserves quantities, notes and native prices', flush=True)


def main():
    migration_test()
    with tempfile.TemporaryDirectory(prefix='aperture-token-price-tests-') as directory:
        target = Path(directory)
        for name in ['AssetPriceProviderRouter.swift', 'AssetPriceProviderConfiguration.swift', 'AssetTokenPriceRouting.swift']:
            (target / name).write_text((ROOT / 'EVMWallet' / name).read_text())
        router = (ROOT / 'EVMWallet/Networking/ProviderReliability/AdaptiveProviderRouter.swift').read_text()
        router = router.replace('import GRDB\n', '')
        router = without_body(router, '    private func loadIfPossible(')
        router = without_body(router, '    private func persist(')
        (target / 'AdaptiveProviderRouter.swift').write_text(router)
        client = (ROOT / 'EVMWallet/AssetPriceClient.swift').read_text()
        declarations = client[:client.index('/// Resolves exact USD prices')].replace('import GRDB\n', '')
        constants = client[client.index('    private static let freshLifetime'):client.index('    private let session:')]
        methods = client[client.index('    static func priceContractAddress('):client.index('    /// The provider market identity')]
        (target / 'AssetPriceClient.swift').write_text(declarations + 'actor AssetPriceClient {\n' + constants + methods + '\n}\n')
        model = (ROOT / 'EVMWallet/WalletHomeModels.swift').read_text()
        model = model[model.index('enum WalletBlockchain:'):model.index('    init?(ankrIdentifier:')]
        model = model.replace('Hashable, Sendable', 'Hashable, Sendable, CaseIterable') + '}\n'
        (target / 'WalletBlockchain.swift').write_text(model)
        for path in (ROOT / 'Scripts/TokenPriceRoutingTests').glob('*.swift'):
            (target / path.name).write_text(path.read_text())
        design = (ROOT / 'EVMWallet/DesignSystem.swift').read_text()
        currency = design[design.index('struct WalletCurrencyContext:'):design.index('private struct WalletCurrencyContextKey:')]
        numbers = design[design.index('enum EnglishNumbers {'):design.index('enum WalletTheme {')]
        (target / 'EnglishNumbers.swift').write_text('import Foundation\n' + currency + numbers + """
            enum WalletCurrencyPreference {
                static let selectedCode = "USD"
                static let defaultCode = "USD"
                static let selectedRatePerUSD: Decimal = 1
            }
            enum WalletLocalization { static func string(_ key: String) -> String { key } }
            """)
        binary = target / 'regression'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        *map(str, target.glob('*.swift')), '-o', str(binary)], check=True)
        subprocess.run([str(binary), *sys.argv[1:]], check=True)

if __name__ == '__main__':
    main()
