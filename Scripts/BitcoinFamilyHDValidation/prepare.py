#!/usr/bin/env python3
"""Run production HD/SQL/signing code on macOS, without launching an iOS simulator.

Usage: python3 Scripts/BitcoinFamilyHDValidation/prepare.py [--live]
The WalletCore 4.7.3 macOS C++ binary and generated Swift bindings are the same
release as the app. Only unrelated UI, Keychain and publication dependencies are
replaced by fixtures. Source slices below are copied from the working tree on
EVERY run; no derivation, discovery, reservation or signing code is reimplemented.
"""
import pathlib, shutil, subprocess, sys, tempfile, urllib.request

def write_if_changed(path, text):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
CACHE = pathlib.Path(tempfile.gettempdir()) / 'aperture-family-hd'
SDK = CACHE / 'walletcore-native'
PACKAGE = CACHE / 'native'
SOURCES = PACKAGE / 'Tests/FamilyHDTests'
CACHE.mkdir(exist_ok=True)
if not (SDK / 'Sources/Generated/WalletCore.h').exists():
    archive = CACHE / 'TrustWalletCore.tar.xz'
    urllib.request.urlretrieve('https://github.com/trustwallet/wallet-core/releases/download/4.7.3/TrustWalletCore-4.7.3.tar.xz', archive)
    SDK.mkdir(exist_ok=True)
    subprocess.run(['tar', '-xf', str(archive), '-C', str(SDK)], check=True)
if not (PACKAGE / 'Sources/WalletCore/Generated').exists():
    shutil.copytree(SDK / 'Sources', PACKAGE / 'Sources/WalletCore', dirs_exist_ok=True)
    for path in (PACKAGE / 'Sources/WalletCore').rglob('*'):
        if path.is_file() and path.suffix != '.swift':
            path.unlink()
    for path in (PACKAGE / 'Sources/WalletCore').rglob('*.swift'):
        path.write_text('import CWalletCore\n' + path.read_text().replace('WalletCoreSwiftProtobuf', 'SwiftProtobuf'))
framework = SDK / 'WalletCoreCommon.xcframework/macos-arm64_x86_64'
c_headers = PACKAGE / 'Sources/CWalletCore/include'
if not (c_headers / 'WalletCore.h').exists():
    shutil.copytree(framework / 'WalletCoreCommon.framework/Headers', c_headers, dirs_exist_ok=True)
    shutil.copy(SDK / 'Sources/Generated/WalletCore.h', c_headers / 'WalletCore.h')
write_if_changed(c_headers.parent / 'module.modulemap', 'module CWalletCore { umbrella header "include/WalletCore.h" export * }\n')
grdb = next((pathlib.Path.home() / 'Library/Developer/Xcode/DerivedData').glob('Oath-*/SourcePackages/checkouts/GRDB.swift'))
write_if_changed(PACKAGE / 'Package.swift', f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FamilyHDValidation", platforms: [.macOS(.v14)],
 dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.31.0"), .package(path: "{grdb}")],
 targets: [.systemLibrary(name: "CWalletCore"),
 .target(name: "WalletCore", dependencies: ["CWalletCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
 linkerSettings: [.unsafeFlags(["-F", "{framework}", "-framework", "WalletCoreCommon", "-lc++"])]),
 .testTarget(name: "FamilyHDTests", dependencies: ["WalletCore", .product(name: "GRDB", package: "GRDB.swift")])], swiftLanguageModes: [.v5])
''')
SOURCES.mkdir(parents=True, exist_ok=True)
expected_files = set()

def source(file):
    return (ROOT / 'Oath' / file).read_text()

def slice_source(file, start, end=None):
    text = source(file)
    text = text[text.index(start):]
    return text[:text.index(end)] if end else text

def save(name, value):
    expected_files.add(name)
    write_if_changed(SOURCES / name, value)

for file in [
    'Networking/BitcoinFamily/BitcoinFamilyHDModels.swift',
    'Networking/BitcoinFamily/BitcoinFamilyHDWalletDatabase.swift',
    'Networking/BitcoinFamily/HDGapDiscovery.swift',
    'Networking/BitcoinFamily/BitcoinCashCashAddrEncoder.swift',
    'Networking/BitcoinFamily/BitcoinFamilyAtomicInteger.swift',
    'Networking/BitcoinFamily/BitcoinFamilyElectrumModels.swift',
    'Networking/BitcoinFamily/PersistentElectrumConnection.swift',
    'Networking/BitcoinFamily/BitcoinRawTransaction.swift',
    'Networking/BitcoinFamily/BitcoinFamilyScriptAddress.swift',
    'Send/SendBitcoinFamilyHDTransactionSigner.swift',
    'Send/SendBitcoinFamilyOptions.swift', 'Send/SendBitcoinOPReturn.swift',
    'Send/SendBitcoinSelectionPlan.swift', 'Send/SendBitcoinDustPolicy.swift',
    'Send/SendBitcoinNestedSegwitTransaction.swift',
]:
    save(pathlib.Path(file).name, source(file))

save('HDDiscovery.swift', slice_source('Networking/BitcoinFamily/BitcoinFamilyHDDiscoveryService.swift',
    'import Foundation', '    func sync(walletID:') +
    slice_source('Networking/BitcoinFamily/BitcoinFamilyHDDiscoveryService.swift', '    static func material('))
save('ProductionModels.swift', 'import Foundation\nimport WalletCore\n' +
    slice_source('BitcoinFamilySupport.swift', 'enum BitcoinFamilyChain:') +
    slice_source('Networking/BitcoinFamily/BitcoinHDWalletModels.swift', 'enum BitcoinHDAddressType:', 'struct BitcoinHDChildKeyCacheEntry:') +
    slice_source('Networking/BitcoinFamily/BitcoinHDWalletModels.swift', 'enum BitcoinHDDerivationError:', 'struct BitcoinHDDerivationService:') +
    slice_source('Networking/BitcoinFamily/BitcoinHDDiscoveryService.swift', 'struct BitcoinHDTransactionReference:', 'actor BitcoinHDDiscoveryService') +
    slice_source('Networking/BitcoinFamily/BitcoinHDWalletDatabase.swift', 'enum BitcoinHDWalletDatabaseError:', 'extension WalletDatabase') +
    slice_source('Networking/BitcoinFamily/BitcoinFamilyIndexedAPIModels.swift', 'struct BitcoinFamilyLosslessInt64:', 'struct BitcoinFamilyBlockCypherResponse:') +
    slice_source('Networking/BitcoinFamily/BitcoinFamilyElectrumClient.swift', 'struct BitcoinFamilyElectrumReadRating:', 'actor BitcoinFamilyElectrumClient') +
    slice_source('Send/SendBitcoinHDTransactionSigner.swift', 'struct SendBitcoinSignedTransaction:', 'enum SendBitcoinHDTransactionSigner') +
    slice_source('Send/SendTransactionModels.swift', 'struct SendResolvedNetworkFee:', '    static func resolve(') + '}\n')
save('ProductionPlanning.swift', 'import Foundation\nimport WalletCore\nenum SendBitcoinTransactionService {\n' +
    slice_source('Send/SendBitcoinTransactionService.swift', '    static func applyingCustomFeeBudget(', '    static func outputs(') +
    slice_source('Send/SendBitcoinTransactionService.swift', '    static func checkedWireOutputIndex(', '    private static func repositoryError(') + '}\n' +
    'enum SendAtomicAmount {\n' + slice_source('Send/SendAtomicAmount.swift', '    static func uint64(', '    static func compare(') +
    slice_source('Send/SendAtomicAmount.swift', '    static func isCanonical(', '    private static func canonical(') + '}\n')
save('ProductionHistory.swift', 'import Foundation\nactor HostHistoryReader {\n' +
    'let historyChain: BitcoinFamilyChain\nlet electrum: BitcoinFamilyElectrumClient\n' +
    'init(chain: BitcoinFamilyChain, client: BitcoinFamilyElectrumClient) { historyChain = chain; electrum = client }\n' +
    slice_source('Networking/BitcoinFamily/BitcoinHDWalletSyncService.swift', '    func transactionEntries(', '    private static func material(') + '}\n')
save('ProductionUTXO.swift', 'import Foundation\n' +
    slice_source('Send/SendBitcoinUTXORepository.swift', 'enum SendBitcoinUTXORepositoryError:', 'struct SendBitcoinUTXORepository:') +
    'struct HostUTXOReader {\nlet electrum: BitcoinFamilyElectrumClient\n' +
    'static let maximumOutputCount = 25_000\nstatic let maximumResponseBytes = 8_388_608\n' +
    'static let maximumRankedFallbackConcurrency = 8\n' +
    slice_source('Send/SendBitcoinUTXORepository.swift', '    private struct HDOutputResponse:', '    init(') +
    'func outputs(database: WalletDatabase, chain: BitcoinFamilyChain) async throws -> [SendBitcoinUTXO] {\n' +
    'try await loadFamilyHDOutputs(database: database, walletID: "fixture", chain: chain) }\n' +
    slice_source('Send/SendBitcoinUTXORepository.swift', '    private func loadHDOutputResponses(', '    private func loadOutputs(') +
    slice_source('Send/SendBitcoinUTXORepository.swift', '    static func readRating(', '    private static func electrumCode(') + '}\n')
save('ProductionElectrumParameters.swift', 'import Foundation\n' +
    slice_source('Networking/BitcoinFamily/BitcoinFamilyElectrumBatchClient.swift', 'private func bitcoinFamilyElectrumBatchParameters(', 'extension BitcoinFamilyElectrumClient') +
    'func hostRPCParameters(chain: BitcoinFamilyChain, method: String, parameter: String) throws -> [AnyEncodable] {\n' +
    'try bitcoinFamilyElectrumBatchParameters(chain: chain, method: method, parameter: parameter) }\n')
for file in HERE.glob('*.swift'):
    save(file.name, file.read_text())
for file in SOURCES.glob('*.swift'):
    if file.name not in expected_files:
        file.unlink()
args = ['swift', 'test', '--package-path', str(PACKAGE)]
if '--live' not in sys.argv:
    args += ['--skip', 'testLive']
subprocess.run(args, check=True)
