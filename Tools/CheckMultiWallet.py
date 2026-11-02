#!/usr/bin/env python3
"""Exercise production vault/session/GRDB code on the Mac, without app launch.

WalletCore's pinned binary is iOS-only. Only its derivation adapter is replaced
by unmistakable non-wallet fixtures. No Keychain, biometrics, network API, or
existing app database is accessed by the checks. Bitcoin sync and price refresh
are replaced with no-network stubs; their real implementations have package tests.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
if "--walletconnect-transactions" in sys.argv or "--permission-batch" in sys.argv or "--permission-batch-races" in sys.argv:
    sys.argv.append("--evm-send")
with tempfile.TemporaryDirectory(prefix="oath-multiwallet-") as temporary:
    work = Path(temporary)
    sources = work / "Sources/WalletValidation"
    sources.mkdir(parents=True)
    files = [
        "Shared/OathHaptics.swift", "Scanner/OathWalletConnectMessage.swift",
        "Wallet/OathWalletVault.swift", "Wallet/OathWalletSession.swift", "Wallet/OathVaultEnvelope.swift",
        "Wallet/OathWalletRestoration.swift", "Wallet/OathMultisigCreation.swift",
        "Home/OathHomePortfolioModel.swift", "Home/OathAssetAmountFormat.swift",
        "Wallet/OathRecoveryPhraseModel.swift",
        "Wallet/OathPassphraseWalletModel.swift", "Wallet/OathWalletRemovalModel.swift",
        "Wallet/OathPrivateKeyModel.swift",
        "Security/OathSecurityPolicy.swift",
        "Security/OathSecurityModel.swift", "Security/OathResetModel.swift",
        "Wallet/OathResetEnvironment.swift", "Wallet/OathCloudBackupService.swift",
        "Wallet/OathImportedPrivateKey.swift",
        "Wallet/OathInstallationVaultStorage.swift", "Wallet/OathInstallationSecurity.swift",
        "Wallet/OathInstallationKeychain.swift", "Wallet/OathDataEnvironment.swift",
        "Passcode/OathPasscodeStore.swift", "Passcode/OathPasscodeSetupModel.swift", "Passcode/OathBiometricSetup.swift",
        "Passcode/OathBiometricCredentialStore.swift", "Passcode/OathBiometricPresentation.swift", "Passcode/OathDeviceBiometrics.swift",
        "Tokens/OathTokenNetwork.swift",
        "Send/OathSendDiagnostics.swift",
        "Import/OathImportCatalog.swift", "Import/OathMnemonicValidator.swift",
        "Localization/OathLocalization.swift", "Localization/OathLanguageCatalog.swift", "Localization/OathStringKey.swift",
    ]
    for file in files:
        shutil.copyfile(root / "OathAtmosphere" / file, sources / Path(file).name)
    # New multisig paths use production descriptors and signing policy. Only
    # WalletCore's iOS-only BIP39 seed call is replaced by the equivalent host KDF.
    multisig = (root / "OathAtmosphere/Wallet/OathBitcoinMultisig.swift").read_text().replace("import WalletCore\n", "")
    (sources / "OathBitcoinMultisig.swift").write_text(multisig)
    tron_multisig = (root / "OathAtmosphere/Wallet/OathTronMultisig.swift").read_text().replace("import WalletCore\n", "")
    (sources / "OathTronMultisig.swift").write_text(tron_multisig)
    solana_multisig = (root / "OathAtmosphere/Wallet/OathSolanaMultisig.swift").read_text().replace("import WalletCore\n", "")
    (sources / "OathSolanaMultisig.swift").write_text(solana_multisig)
    xrpl_multisig = (root / "OathAtmosphere/Wallet/OathXrplMultisig.swift").read_text().replace("import WalletCore\n", "")
    (sources / "OathXrplMultisig.swift").write_text(xrpl_multisig)
    stellar_multisig = (root / "OathAtmosphere/Wallet/OathStellarMultisig.swift").read_text().replace("import WalletCore\n", "")
    (sources / "OathStellarMultisig.swift").write_text(stellar_multisig)
    (sources / "OathAptosMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathAptosMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "OathEVMMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathEVMMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "OathTonMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathTonMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "OathThorchainMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathThorchainMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "OathNearMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathNearMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "OathSuiMultisig.swift").write_text((root / "OathAtmosphere/Wallet/OathSuiMultisig.swift").read_text().replace("import WalletCore\n", ""))
    (sources / "HostBIP39.swift").write_text("""
import Foundation
import CommonCrypto
struct Bech32 { static func decode(string: String) -> Data? { nil } }
struct HDWallet {
    let seed: Data
    enum Coin { case ethereum, ton, tron, xrp, stellar, aptos, sui, near, thorchain }
    struct Key { let data: Data }
    // This host harness does not emulate WalletCore TRON HD derivation. Raw-key
    // material is tested here; phrase derivation needs its own independent vectors.
    func getKey(coin: Coin, derivationPath: String) -> Key? { nil }
    init?(mnemonic: String, passphrase: String, check: Bool) {
        let password = Data(mnemonic.decomposedStringWithCompatibilityMapping.utf8)
        let salt = Data(("mnemonic" + passphrase.decomposedStringWithCompatibilityMapping).utf8)
        var output = Data(count: 64)
        let result = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { out in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self), p.count,
                s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                2048, out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count)
        } } }
        guard result == kCCSuccess else { return nil }
        seed = output
    }
}
""")
    validator = sources / "OathMnemonicValidator.swift"
    validator.write_text(validator.read_text().replace('Bundle.main.url(forResource: $0, withExtension: $1)',
        'URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_WORDLISTS"]!).appendingPathComponent($0 + "." + $1)'))

    # Preserve the production preparation loop for targeted migration checks.
    # Only ownership/derivation needs the unavailable iOS WalletCore binary.
    legacy_source = (root / "OathAtmosphere/Wallet/OathLegacyUpgrade.swift").read_text()
    if "--legacy-upgrade" in sys.argv:
        legacy = legacy_source.split("    private static func verifyOwnership")[0].replace("import WalletCore\n", "")
        legacy += '''
        private static func verifyOwnership(_ secret: OathWalletSecret, accounts: [LegacyAccount]) throws {
            let profile = try OathWalletEngine.profile(for: secret)
            for account in accounts {
                try Task.checkCancellation()
                let network = try chain(account.networkID)
                guard profile.addresses.contains(where: { $0.chain == network && $0.address == account.address }) else {
                    throw LegacyUpgradeError.addressMismatch
                }
            }
        }
        private static func privateKey(_ data: Data, networks: [OathImportChain], accounts: [LegacyAccount]) throws -> OathImportedPrivateKey {
            // This harness verifies recovery migration control flow, not key import.
            throw LegacyUpgradeError.unsupportedWallet
        }
    }
    '''
        validator = sources / "OathMnemonicValidator.swift"
        validator.write_text(validator.read_text().replace(
            'Bundle.main.url(forResource: $0, withExtension: $1)',
            'URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_WORDLISTS"]!).appendingPathComponent($0 + "." + $1)'))
    else:
        legacy = legacy_source.split("enum OathLegacyUpgrade {")[0].replace("import WalletCore\n", "")
        legacy += '''enum OathLegacyUpgrade {
        static let sourceURL = URL(fileURLWithPath: "/nonexistent-oath-host-fixture/legacy.sqlite")
        static func rootID(for source: LegacyWalletSnapshot) throws -> UUID {
            guard let id = source.wallets.first.flatMap({ UUID(uuidString: $0.id) }) else { throw LegacyUpgradeError.invalidSource }
            return id
        }
        static func prepare(_ source: LegacyWalletSnapshot, secrets: any OathLegacySecretReading) throws
            -> (OathVaultContents, LegacyUpgradeBatch) { throw LegacyUpgradeError.unsupportedWallet }
    }
    '''
    if "--vault-handoff" in sys.argv:
        validator = sources / "OathMnemonicValidator.swift"
        validator.write_text(validator.read_text().replace(
            'Bundle.main.url(forResource: $0, withExtension: $1)',
            'URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_WORDLISTS"]!).appendingPathComponent($0 + "." + $1)'))
    (sources / "FixtureLegacyBoundary.swift").write_text(legacy)
    engine = (root / "OathAtmosphere/Wallet/OathWalletEngine.swift").read_text()
    models = engine.split("enum OathWalletEngine {")[0].replace("import WalletCore\n", "")
    chain_properties = "extension OathImportChain {\n" + engine[engine.index("    var walletPath: String {"):]
    fixture = '''
enum OathWalletEngine {
    static func fixtureSolanaAddress(_ secret: OathWalletSecret, path: String) -> String {
        // Intentionally synthetic public metadata; never represents a real key.
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return "FixtureSo1" + SHA256.hash(data: Data((secret.id.uuidString + path).utf8)).map { String(alphabet[Int($0) % 58]) }.joined()
    }
    static func solanaReceiveAddresses(for secret: OathWalletSecret, account: AccountRecord) throws -> [SolanaReceiveAddress] {
        if secret.privateKey != nil || secret.solanaMultisig != nil { return [.init(path: account.derivationPath, address: account.address)] }
        let index = SolanaDerivation.accountIndex(in: account.derivationPath) ?? account.accountIndex
        var paths = try SolanaDerivation.allCases.map { try $0.path(accountIndex: index) }
        if !paths.contains(account.derivationPath) { paths.append(account.derivationPath) }
        return paths.map { .init(path: $0, address: fixtureSolanaAddress(secret, path: $0)) }
    }
    static func create(id: UUID = UUID()) throws -> OathWalletSecret {
        .init(id: id, mnemonic: "synthetic generated fixture " + id.uuidString.lowercased(),
              language: "english", createdAt: .now, backedUp: false)
    }
    static func imported(_ phrase: OathValidatedMnemonic, id: UUID = UUID()) throws -> OathWalletSecret {
        .init(id: id, mnemonic: phrase.phrase, language: phrase.language,
              createdAt: .now, backedUp: true, imported: true)
    }
    static func imported(_ material: OathImportedPrivateKey, id: UUID = UUID()) throws -> OathWalletSecret {
        guard material.isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: true,
                     imported: true, privateKey: material)
    }
    static func profile(for secret: OathWalletSecret, chains: Set<OathImportChain>? = nil) throws -> OathWalletProfile {
        DerivationGate.shared.waitIfArmed()
        if let multisig = secret.evmMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.tonMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.thorchainMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.nearMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.suiMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.aptosMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.stellarMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.xrplMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.solanaMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.tronMultisig { return try multisigProfile(for: secret, material: multisig) }
        if let multisig = secret.bitcoinMultisig { return try multisigProfile(for: secret, material: multisig) }
        let accounts = secret.restoration?.accounts ?? (secret.privateKey?.networks ?? OathImportChain.allCases).map {
            BackupWallet.Account(network: $0.id, derivationPath: secret.privateKey == nil ? $0.walletPath : "imported", index: 0)
        }
        return .init(id: secret.id, addresses: accounts.filter { chains == nil || chains!.contains(OathImportChain(rawValue:$0.network)!) }.map {
            .init(chain: OathImportChain(rawValue: $0.network)!, address: $0.network == "solana" ? fixtureSolanaAddress(secret, path: $0.derivationPath) : "synthetic-address-" + secret.id.uuidString + $0.network + ($0.index == 0 ? "" : ":" + String($0.index)),
                  path: $0.derivationPath, accountIndex: $0.index)
        }, createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
    static func privateKey(for secret: OathWalletSecret, account: OathPrivateKeyAccount) throws -> OathPrivateKeyExport {
        DerivationGate.shared.waitIfArmed()
        if let origin = account.utxo, let network = UTXONetwork(rawValue: account.chain.id) {
            let source: BitcoinPrivateKeySource
            if let key = secret.privateKey {
                if let extended = try key.extendedKey(for: network) { source = .extended(extended) }
                else { source = .single(key.bytes, compressed: key.compressed != false) }
            } else { source = .seed(Data(0..<32), account: origin.accountIndex) }
            return .init(value: try network.privateKeyWIF(source: source, address: origin.address), format: "WIF")
        }
        guard account.address == (account.chain == .solana ? fixtureSolanaAddress(secret, path: account.path) : "synthetic-address-" + secret.id.uuidString + account.chain.id) else {
            throw OathWalletError.derivationFailed
        }
        return .init(value: "synthetic-export-" + secret.id.uuidString + account.chain.id + account.path, format: "Synthetic fixture")
    }
}
'''
    if "--walletconnect" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: OathImportChain(rawValue: $0.network)!.isEVM && secret.privateKey != nil ? (try! ArcSendCrypto.address(privateKey: secret.privateKey!.bytes)) : $0.network == "solana" ?')
    # Production imported-key message signer; HD adapter requires the iOS binary.
    message_adapter = (root / "OathAtmosphere/Wallet/OathWalletConnectSigning.swift").read_text().replace("import WalletCore\n", "")
    start = message_adapter.index('            let passphrase =')
    end = message_adapter.index('            bytes = key.data') + len('            bytes = key.data')
    message_adapter = message_adapter[:start] + '            throw OathWalletError.derivationFailed // Host authentication tests never derive a real HD wallet.' + message_adapter[end:]
    (sources / "WalletConnectMessageAdapter.swift").write_text(message_adapter)
    # Exercise the production private-key/extended-descriptor adapter on macOS.
    # Only the mnemonic-to-seed provider requires the iOS-only WalletCore binary.
    adapter = (root / "OathAtmosphere/Wallet/OathBitcoinWallet.swift").read_text().split("extension OathWalletEngine")[0]
    (sources / "PrivateDescriptorAdapter.swift").write_text(adapter.replace("import WalletCore\n", ""))
    # Keep the production quote type after the vault gained send authorization.
    # This authentication harness never signs or invokes a network service.
    send_types = (root / "OathAtmosphere/Send/OathBitcoinSendService.swift").read_text().split("actor OathBitcoinSendService")[0]
    (sources / "SendTypes.swift").write_text(send_types)
    sui_types = (root / "OathAtmosphere/Send/OathSuiSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "SuiSendTypes.swift").write_text(sui_types)
    if "--sui-send" in sys.argv or "--sui-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "sui" && secret.privateKey != nil ? (try! SuiSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathSuiWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "SuiSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "SuiSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signSui(_ plan:SuiSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> SuiSignedSend { throw SuiSendError.signing } }")
    xrpl_types = (root / "OathAtmosphere/Send/OathXrplSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "XrplSendTypes.swift").write_text(xrpl_types)
    if "--xrpl-send" in sys.argv or "--xrpl-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "xrpl" && secret.privateKey != nil ? (try! XrplSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathXrplWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "XrplSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "XrplSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signXrpl(_ plan:XrplSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> XrplSignedSend { throw XrplSendError.signing } }")
    stellar_types = (root / "OathAtmosphere/Send/OathStellarSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "StellarSendTypes.swift").write_text(stellar_types)
    if "--stellar-send" in sys.argv or "--stellar-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "stellar" && secret.privateKey != nil ? (try! StellarSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathStellarWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "StellarSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "StellarSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signStellar(_ plan:StellarSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> StellarSignedSend { throw StellarSendError.signing } }")
    polkadot_types = (root / "OathAtmosphere/Send/OathPolkadotSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "PolkadotSendTypes.swift").write_text(polkadot_types)
    (sources / "PolkadotSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signPolkadot(_ plan:PolkadotSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> PolkadotSignedSend { throw PolkadotSendError.signing } }\n")
    evm_types = (root / "OathAtmosphere/Send/OathEVMSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "EVMSendTypes.swift").write_text(evm_types)
    if "--permission-batch-races" in sys.argv:
        # This mode exercises all three imported-key signers in one process.
        # Select addresses with the same real crypto modules as each signer.
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: secret.privateKey != nil ? (try! permissionRaceAddress(network: $0.network, bytes: secret.privateKey!.bytes)) : $0.network == "solana" ?')
        fixture += '''
func permissionRaceAddress(network: String, bytes: Data) throws -> String {
    if OathImportChain(rawValue: network)?.isEVM == true { return try EVMSendCrypto.address(privateKey: bytes) }
    if network == "tron" { return try TronSendCrypto.address(privateKey: bytes) }
    if network == "solana" { return try SolanaSendCrypto.address(privateKey: bytes) }
    throw OathWalletError.derivationFailed
}
'''
    if "--evm-send" in sys.argv or "--evm-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: OathImportChain(rawValue:$0.network)?.isEVM == true && secret.privateKey != nil ? (try! EVMSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathEVMSigning.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; host tests use public fixture keys.'+adapter[end:]
        (sources / "EVMSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "EVMSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signEVM(_ plan:EVMSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> EVMSignedSend { throw EVMSendError.signing } }\n")
    arc_types = (root / "OathAtmosphere/Send/OathArcSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "ArcSendTypes.swift").write_text(arc_types)
    if "--arc-send" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "arc" && secret.privateKey != nil ? (try! ArcSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathArcSigning.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "ArcSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "ArcSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signArc(_ plan:ArcSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> ArcSignedSend { throw ArcSendError.signing } }")
    tron_types = (root / "OathAtmosphere/Send/OathTronSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "TronSendTypes.swift").write_text(tron_types)
    if "--tron-send" in sys.argv or "--permission-batch-races" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "tron" && secret.privateKey != nil ? (try! TronSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathTronWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "TronSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "TronSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signTron(_ plan:TronSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> TronSignedSend { throw TronSendError.signing } }")
    near_types = (root / "OathAtmosphere/Send/OathNearSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "NearSendTypes.swift").write_text(near_types)
    if "--near-send" in sys.argv or "--near-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "near" && secret.privateKey != nil ? (try! NearSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathNearWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "NearSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "NearSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signNear(_ plan:NearSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> NearSignedSend { throw NearSendError.signing }; static func nearPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data { throw NearSendError.signing } }")
    aptos_types = (root / "OathAtmosphere/Send/OathAptosSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "AptosSendTypes.swift").write_text(aptos_types)
    if "--aptos-send" in sys.argv or "--aptos-multisig" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "aptos" && secret.privateKey != nil ? (try! AptosSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathAptosWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "AptosSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "AptosSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signAptos(_ plan:AptosSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> AptosSignedSend { throw AptosSendError.signing }; static func aptosPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data { throw AptosSendError.signing } }")
    thorchain_types = (root / "OathAtmosphere/Send/OathThorchainSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "ThorchainSendTypes.swift").write_text(thorchain_types)
    if "--ton-multisig" in sys.argv or "--thorchain-multisig" in sys.argv or "--thorchain-send" in sys.argv or "--thorchain-walletconnect" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "thorchain" && secret.privateKey != nil ? (try! ThorchainSendCrypto.address(publicKey:ThorchainSendCrypto.publicKey(privateKey:secret.privateKey!.bytes),network:.mainnet)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathThorchainWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "ThorchainSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "ThorchainSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signThorchain(_ plan:ThorchainSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> ThorchainSignedSend { throw ThorchainSendError.signing }; static func thorchainPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data { throw ThorchainSendError.signing }; static func signThorchainWalletConnect(_ request:ThorchainWalletConnectRequest,secret:OathWalletSecret,account:AccountRecord) throws -> SolanaJSON { throw ThorchainSendError.signing } }")
    solana_types = (root / "OathAtmosphere/Send/OathSolanaSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "SolanaSendTypes.swift").write_text(solana_types)
    if "--solana-send" in sys.argv or "--solana-multisig" in sys.argv or "--permission-batch-races" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "solana" && secret.privateKey != nil ? (try! SolanaSendCrypto.address(privateKey:secret.privateKey!.bytes)) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathSolanaSigning.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "SolanaSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "SolanaSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signWalletConnectSolana(_ request:WalletConnectSolanaRequest,secret:OathWalletSecret,account:AccountRecord) throws -> WalletConnectSolanaSigned { throw SolanaSendError.signing }; static func signSolana(_ plan:SolanaSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> SolanaSignedSend { throw SolanaSendError.signing }; static func solanaPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data { throw SolanaSendError.signing } }")
    ton_types = (root / "OathAtmosphere/Send/OathTonSendService.swift").read_text().split("/// App-lifetime")[0]
    (sources / "TonSendTypes.swift").write_text(ton_types)
    if "--ton-multisig" in sys.argv or "--ton-send" in sys.argv:
        fixture = fixture.replace('address: $0.network == "solana" ?', 'address: $0.network == "ton" && secret.privateKey != nil ? (try! TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:secret.privateKey!.bytes))) : $0.network == "solana" ?')
        adapter = (root / "OathAtmosphere/Wallet/OathTonWallet.swift").read_text().replace("import WalletCore\n", "")
        start = adapter.index('            let passphrase =')
        end = adapter.index('            bytes = key.data')+len('            bytes = key.data')
        adapter = adapter[:start]+'            throw OathWalletError.derivationFailed // HD adapter is iOS-only; this host test imports a public fixture key.'+adapter[end:]
        (sources / "TonSigningAdapter.swift").write_text(adapter)
    else:
        (sources / "TonSigningAdapter.swift").write_text("import Foundation\nimport OathAnkr\nimport OathDatabase\nextension OathWalletEngine { static func signTon(_ plan:TonSendPlan, secret:OathWalletSecret, account:AccountRecord) throws -> TonSignedSend { throw TonSendError.signing }; static func tonPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data { throw TonSendError.signing } }")
    if "--aezeed" in sys.argv or "--electrum" in sys.argv or "--seed-password" in sys.argv:
        # Real production import and aezeed profile branch. The BIP39-only
        # WalletCore adapter remains stubbed in this host harness.
        real_import = engine[engine.index("    static func imported(_ phrase:"):engine.index("    static func profile(for secret:")]
        a = fixture.index("    static func imported(_ phrase:")
        b = fixture.index("    static func imported(_ material:", a)
        fixture = fixture[:a] + real_import + fixture[b:]
        a = engine.index("        if let material = secret.electrum {")
        b = engine.index("        if let material = secret.evmMultisig", a)
        fixture = fixture.replace("        DerivationGate.shared.waitIfArmed()", engine[a:b] + "        DerivationGate.shared.waitIfArmed()", 1)
    (sources / "FixtureDerivation.swift").write_text("import OathBitcoin\nimport OathAnkr\nimport OathDatabase\nimport CryptoKit\n" + models + fixture + chain_properties + """
extension OathWalletEngine {
    static func signBitcoin(_ plan: BitcoinSendPlan, secret: OathWalletSecret, accounts: [AccountRecord]) throws -> BitcoinSignedSend {
        // Signing has separate deterministic package tests; this harness must
        // fail closed if an authentication check unexpectedly attempts a send.
        throw BitcoinSendError.signing
    }
    static func bitcoinDescriptor(for secret: OathWalletSecret, account: UInt32, network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        if let material = secret.electrum {
            guard network == .bitcoin, account == 0, secret.hasValidMaterial else { throw OathWalletError.invalidPhrase }
            return try ElectrumBitcoin.wallet(material)
        }
        if let aezeed = secret.aezeed {
            guard network == .bitcoin, secret.hasValidMaterial else { throw OathWalletError.invalidPhrase }
            return try BitcoinKeys.aezeedWallet(entropy: aezeed.entropy, account: account)
        }
        if let multisig = secret.bitcoinMultisig { return try multisig.descriptor() }
        if let key = secret.privateKey { return try key.bitcoinDescriptor() }
        return try network.wallet(seed: Data(0..<32), account: account)
    }
}
""")
    if "--aezeed" in sys.argv or "--electrum" in sys.argv:
        # Use the shipped descriptor builder for these real Bitcoin receive tests.
        # Its mnemonic-to-seed dependency is the CommonCrypto BIP39 host adapter above.
        generated = sources / "FixtureDerivation.swift"
        text = generated.read_text()
        shipped = (root / "OathAtmosphere/Wallet/OathBitcoinWallet.swift").read_text()
        signature = "    static func bitcoinDescriptor(for secret:"
        def descriptor_method(code):
            start = code.index(signature)
            end = code.index("\n    }\n", start) + len("\n    }")
            return code[start:end]
        generated.write_text(text.replace(descriptor_method(text), descriptor_method(shipped), 1))
    (sources / "FixturePublicNetworking.swift").write_text("""
import OathAnkr
import Foundation
import OathMarketData
// This harness never starts catalog searches or token additions. Keep their
// cancellation boundary inert alongside the other public-network fixtures;
// TokenLookupValidation exercises the production token selection model.
@MainActor final class OathTokenSelectionModel {
    func cancel() { }
}
enum OathTokenAddress {
    static func checksum(_ address: String) -> String {
        preconditionFailure("Catalog artwork belongs to TokenLookupValidation, not wallet selection tests")
    }
}
actor OathTokenService {
    static let shared = OathTokenService()
    func resolveForAdding(_ token: OathTokenDefinition, owner: String?) async throws -> OathTokenDefinition {
        preconditionFailure("Token metadata requests belong to TokenLookupValidation, not wallet selection tests")
    }
}
// Background send recovery is outside this authentication harness. Like sync
// below, it is replaced at the network boundary, never in vault authorization.
actor OathStellarSendService {
    static let shared = OathStellarSendService()
    func recover(vault: OathWalletVault) async { }
}
actor OathTronSendService {
    static let shared = OathTronSendService()
    func recover(vault: OathWalletVault) async { }
}
actor OathNearSendService {
    static let shared = OathNearSendService()
    func recover(vault: OathWalletVault) async { }
}
actor OathXrplSendService {
    static let shared = OathXrplSendService()
    func recover(vault: OathWalletVault) async { }
}
actor OathSuiSendService {
    static let shared = OathSuiSendService()
    func recover(vault: OathWalletVault) async { }
}
actor OathBitcoinSendService {
    static let shared = OathBitcoinSendService()
    static let cash = OathBitcoinSendService()
    static let litecoin = OathBitcoinSendService()
    static let dogecoin = OathBitcoinSendService()
    func recover(vault: OathWalletVault) async { }
}
@MainActor final class OathSendStatusTracking {
    static let shared = OathSendStatusTracking()
    func beginReset() async {}
    func endReset() {}
}
actor OathPostSendBalanceRefresh {
    static let shared = OathPostSendBalanceRefresh()
    func resume(vault: OathWalletVault) async { }
    func pause() async { }
    func reset() async { }
}
actor OathBitcoinSync {
    static let shared = OathBitcoinSync()
    private var refreshFailure: (any Error)?
    func setRefreshFailure(_ error: (any Error)?) { refreshFailure = error }
    func refresh(accountID: String, vault: OathWalletVault) async throws {
        try Task.checkCancellation()
        if let refreshFailure { throw refreshFailure }
    }
    func cancel() async { }
}
actor OathAnkrSync {
    static let shared = OathAnkrSync()
    private var refreshFailure: (any Error)?
    private(set) var completedSolanaRefreshes = 0
    func setRefreshFailure(_ error: (any Error)?) { refreshFailure = error }
    func refresh(walletID: String) async throws {
        try Task.checkCancellation()
        if let refreshFailure { throw refreshFailure }
    }
    func refreshBalances(walletID: String) async throws { try Task.checkCancellation() }
    func refreshSolana(accountID: String) async throws {
        try Task.checkCancellation(); completedSolanaRefreshes += 1
    }
    func refreshTron(accountID: String) async throws { try Task.checkCancellation() }
    func refreshTon(accountID: String) async throws { try Task.checkCancellation() }
    func refreshAptos(accountID: String) async throws { try Task.checkCancellation() }
    func refreshThorchain(accountID: String) async throws { try Task.checkCancellation() }
    func refreshSui(accountID: String) async throws { try Task.checkCancellation() }
    func refreshNear(accountID: String) async throws { try Task.checkCancellation() }
    func refreshPolkadot(accountID: String) async throws { try Task.checkCancellation() }
    func refreshXrpl(accountID: String) async throws { try Task.checkCancellation() }
    func refreshStellar(accountID: String) async throws { try Task.checkCancellation() }
    func refreshHyperEVM(accountID: String) async throws { try Task.checkCancellation() }
    func refreshIndexedEVM(accountID: String, chain: IndexedEVMChain) async throws { try Task.checkCancellation() }
    func refreshRobinhood(accountID: String) async throws { try Task.checkCancellation() }
    func refreshArc(accountID: String) async throws { try Task.checkCancellation() }
    func cancel() async { }
}
actor OathMarketEnvironment {
    static let shared = OathMarketEnvironment()
    func service() async throws -> FixtureMarketService { FixtureMarketService() }
}
struct FixtureMarketService: Sendable {
    func quote(for asset: MarketAsset) async throws { try Task.checkCancellation() }
}
""")
    shutil.copyfile(root / "Tools/CheckMultiWallet.swift", sources / "CheckMultiWallet.swift")
    if "--aezeed" in sys.argv or "--electrum" in sys.argv or "--seed-password" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        check_name = "CheckSeedPasswordWallets.swift" if "--seed-password" in sys.argv else "CheckElectrumImport.swift" if "--electrum" in sys.argv else "CheckAezeedImport.swift"
        shutil.copyfile(root / "Tools" / check_name, sources / check_name)
        shutil.copyfile(root / "OathAtmosphere/Import/OathRecoveryPhraseDraft.swift", sources / "OathRecoveryPhraseDraft.swift")
    if "--evm-multisig" in sys.argv or "--dogecoin-multisig" in sys.argv or "--bitcoin-cash-multisig" in sys.argv or "--litecoin-multisig" in sys.argv or "--ton-multisig" in sys.argv or "--thorchain-multisig" in sys.argv or "--near-multisig" in sys.argv or "--sui-multisig" in sys.argv or "--aptos-multisig" in sys.argv or "--stellar-multisig" in sys.argv or "--xrpl-multisig" in sys.argv or "--bitcoin-multisig" in sys.argv or "--tron-multisig" in sys.argv or "--solana-multisig" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        check_name = "CheckEVMMultisig.swift" if "--evm-multisig" in sys.argv else "CheckDogecoinMultisig.swift" if "--dogecoin-multisig" in sys.argv else "CheckBitcoinCashMultisig.swift" if "--bitcoin-cash-multisig" in sys.argv else "CheckLitecoinMultisig.swift" if "--litecoin-multisig" in sys.argv else "CheckTonMultisig.swift" if "--ton-multisig" in sys.argv else "CheckThorchainMultisig.swift" if "--thorchain-multisig" in sys.argv else "CheckNearMultisig.swift" if "--near-multisig" in sys.argv else "CheckSuiMultisig.swift" if "--sui-multisig" in sys.argv else "CheckAptosMultisig.swift" if "--aptos-multisig" in sys.argv else "CheckStellarMultisig.swift" if "--stellar-multisig" in sys.argv else "CheckXrplMultisig.swift" if "--xrpl-multisig" in sys.argv else "CheckSolanaMultisig.swift" if "--solana-multisig" in sys.argv else "CheckTronMultisig.swift" if "--tron-multisig" in sys.argv else "CheckBitcoinMultisig.swift"
        shutil.copyfile(root / "Tools" / check_name, sources / check_name)
        draft = (root / "OathAtmosphere/Import/OathMultisigSetup.swift").read_text().split("struct OathMultisigChainScreen")[0]
        (sources / "OathMultisigDraft.swift").write_text(draft.replace("import SwiftUI", "import Foundation"))

    if "--vault-handoff" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckVaultHandoff.swift", sources / "CheckVaultHandoff.swift")
        shutil.copyfile(root / "OathAtmosphere/Wallet/OathVaultImportPreparation.swift", sources / "OathVaultImportPreparation.swift")
        inbox = (root / "OathAtmosphere/Import/OathVaultImportFlow.swift").read_text().split("extension View {")[0]
        (sources / "HandoffInbox.swift").write_text(inbox.replace("import SwiftUI", "import Foundation"))
        # Text decoding is iOS WalletCore code. These host checks exercise raw
        # saved scalars and reject text, never pretending to test that adapter.
        (sources / "HandoffDecodeStub.swift").write_text("import Foundation\nextension OathWalletEngine { static func importedPrivateKey(_ input: String, choice: OathPrivateKeyChoice) throws -> OathImportedPrivateKey { throw OathWalletError.invalidPrivateKey } }\n")
    if "--home-startup" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckHomeStartup.swift", sources / "CheckHomeStartup.swift")
        # Compile the real history presentation model. Its market-detail sibling
        # is not part of this local-index/lock regression test.
        activity = (root / "OathAtmosphere/Assets/OathAssetDetailModel.swift").read_text()
        (sources / "ActivityModel.swift").write_text("import Foundation\nimport Observation\nimport OathDatabase\nimport OathDiagnostics\n" + activity[activity.index("@MainActor @Observable final class OathChainActivityModel"):])
    if "--balance-history" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckBalanceHistoryLifecycle.swift", sources / "CheckBalanceHistoryLifecycle.swift")
        # Exercise failures and slow provider work through the fixture boundary.
        replacement_count = 0
        for candidate in sources.glob("*.swift"):
            text = candidate.read_text()
            old = "func refresh(accountID: String, vault: OathWalletVault) async throws {\n        try Task.checkCancellation()"
            if old in text:
                replacement_count += text.count(old)
                candidate.write_text(text.replace(old, old + "; try await BalanceHistoryFailure.shared.check()"))
        if replacement_count != 1:
            raise RuntimeError("Balance history provider fixture was not installed exactly once")
    if "--sui-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckSuiSendAuthorization.swift", sources / "CheckSuiSendAuthorization.swift")
    if "--xrpl-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckXrplSendAuthorization.swift", sources / "CheckXrplSendAuthorization.swift")
    if "--tron-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckTronSendAuthorization.swift", sources / "CheckTronSendAuthorization.swift")
    if "--near-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckNearSendAuthorization.swift", sources / "CheckNearSendAuthorization.swift")
    if "--evm-send" in sys.argv or "--solana-send" in sys.argv:
        shutil.copyfile(root / "Tools/CheckSendPreparation.swift", sources / "CheckSendPreparation.swift")
    if "--evm-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        if "--walletconnect-transactions" in sys.argv:
            (sources / "EVMSendTypes.swift").unlink()
            shutil.copyfile(root / "OathAtmosphere/Send/OathEVMSendService.swift", sources / "EVMSendService.swift")
            shutil.copyfile(root / "OathAtmosphere/Scanner/OathWalletConnectTransactionProgress.swift", sources / "OathWalletConnectTransactionProgress.swift")
            shutil.copyfile(root / "Tools/CheckWalletConnectTransactions.swift", sources / "CheckWalletConnectTransactions.swift")
            with (sources / "FixturePublicNetworking.swift").open("a") as stub:
                stub.write('''
extension OathPostSendBalanceRefresh { func submitted(walletID: String, networkID: String) async {} }
''')
        else:
            shutil.copyfile(root / ("Tools/CheckPermissionBatchRaces.swift" if "--permission-batch-races" in sys.argv else "Tools/CheckPermissionBatchAuthorization.swift" if "--permission-batch" in sys.argv else "Tools/CheckEVMSendAuthorization.swift"), sources / "CheckEVMSendAuthorization.swift")
    if "--arc-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckArcSendAuthorization.swift", sources / "CheckArcSendAuthorization.swift")
    if "--aptos-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckAptosSendAuthorization.swift", sources / "CheckAptosSendAuthorization.swift")
    if "--thorchain-send" in sys.argv or "--thorchain-walletconnect" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / ("Tools/CheckThorchainWalletConnectAuthorization.swift" if "--thorchain-walletconnect" in sys.argv else "Tools/CheckThorchainSendAuthorization.swift"), sources / "CheckThorchainSendAuthorization.swift")
    if "--solana-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckSolanaSendAuthorization.swift", sources / "CheckSolanaSendAuthorization.swift")
    if "--ton-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckTonSendAuthorization.swift", sources / "CheckTonSendAuthorization.swift")
    if "--stellar-send" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckStellarSendAuthorization.swift", sources / "CheckStellarSendAuthorization.swift")
    if "--passphrase" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        (sources / "CheckPassphraseMain.swift").write_text("""
@main struct CheckPassphraseMain {
    @MainActor static func main() async throws {
        _ = try await CheckMultiWallet.checkPassphraseWallets()
    }
}
""")
    if "--lifecycle" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        (sources / "CheckLifecycleMain.swift").write_text("""
@main struct CheckLifecycleMain {
    @MainActor static func main() async throws {
        _ = try await CheckMultiWallet.checkWalletLifecycle()
        _ = try await CheckMultiWallet.checkReset()
    }
}
""")
    if "--legacy-upgrade" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckLegacyUpgrade.swift", sources / "CheckLegacyUpgrade.swift")
    if "--cloud-restore" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        (sources / "CheckCloudRestoreMain.swift").write_text("""
@main struct CheckCloudRestoreMain {
    @MainActor static func main() async throws {
        _ = try await CheckMultiWallet.checkCloudRestore()
    }
}
""")
    if "--envelope" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckMultiWalletEnvelope.swift", sources / "CheckMultiWalletEnvelope.swift")
    if "--security" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        (sources / "CheckSecurityMain.swift").write_text("""
@main struct CheckSecurityMain {
    @MainActor static func main() async throws {
        let checks = try await CheckMultiWallet.checkSecurity()
        print("Passed \\(checks) security host checks. No simulator, device, user Keychain or network was used.")
    }
}
""")
    if "--private-keys" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckHDPrivateKeys.swift", sources / "CheckHDPrivateKeys.swift")
    if "--walletconnect" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckWalletConnectAuthorization.swift", sources / "CheckWalletConnectAuthorization.swift")
    if "--authentication" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        (sources / "CheckAuthenticationMain.swift").write_text("""
@main struct CheckAuthenticationMain {
    @MainActor static func main() async throws {
        let fallback = try await CheckMultiWallet.checkBiometricFallback()
        let security = try await CheckMultiWallet.checkSecurity()
        print("Passed \\(fallback) biometric fallback checks and \\(security) security host checks. No simulator, device, user Keychain or network was used.")
    }
}
""")
    if "--protected-startup" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckProtectedWalletStartup.swift", sources / "CheckProtectedWalletStartup.swift")
    if "--session-diagnostics" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckWalletSessionDiagnostics.swift", sources / "CheckWalletSessionDiagnostics.swift")
        shutil.copyfile(root / "Packages/OathNativeRefresh/Sources/OathNativeRefresh/RefreshAction.swift", sources / "RefreshAction.swift")
    if "--authentication-diagnostics" in sys.argv:
        check = sources / "CheckMultiWallet.swift"
        check.write_text(check.read_text().replace("@main", ""))
        shutil.copyfile(root / "Tools/CheckBiometricDiagnostics.swift", sources / "CheckBiometricDiagnostics.swift")
    shutil.copyfile(root / "Tools/CheckBiometricFallback.swift", sources / "CheckBiometricFallback.swift")
    shutil.copyfile(root / "Tools/CheckPassphraseWallets.swift", sources / "CheckPassphraseWallets.swift")
    shutil.copyfile(root / "Tools/CheckCloudRestore.swift", sources / "CheckCloudRestore.swift")
    shutil.copyfile(root / "Tools/CheckUTXOWallets.swift", sources / "CheckUTXOWallets.swift")
    shutil.copyfile(root / "Tools/CheckWalletLifecycle.swift", sources / "CheckWalletLifecycle.swift")
    shutil.copyfile(root / "Tools/CheckLastWalletReset.swift", sources / "CheckLastWalletReset.swift")
    # Unselected chain signers must never execute in this authentication harness.
    # Real request/signature behavior is exercised by each chain's package tests.
    generated = "\n".join(file.read_text() for file in sources.glob("*.swift"))
    unavailable = ["import Foundation", "import OathAnkr", "import OathBitcoin", "import OathDatabase"]
    import re
    for chain in ["Bitcoin", "Ton", "Tron", "Polkadot", "Sui", "Near", "Stellar", "Xrpl"]:
        code = (root / ("OathAtmosphere/Wallet/Oath" + chain + "Wallet.swift")).read_text()
        for match in re.finditer(r"(?:@concurrent )?static func (signWalletConnect\w+|suiPublicKey)\([^{}]+?\) (?:async )?throws -> [^{]+\{", code):
            if "static func " + match.group(1) + "(" not in generated:
                unavailable.append("extension OathWalletEngine { " + match.group(0) + ' preconditionFailure("Unselected chain signer is outside this host harness") } }')
        for name in ["OathBitcoinConnectSignature", "OathTonWalletConnectSignature"]:
            if "enum " + name not in generated:
                match = re.search(r"enum " + name + r"[^}]+}", code)
                if match: unavailable.append(match.group(0))
    (sources / "UnselectedSigningAdapters.swift").write_text("\n".join(unavailable))
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "WalletValidation", platforms: [.macOS("15.5")],
    dependencies: [
        .package(path: %s), .package(path: %s), .package(path: %s), .package(path: %s), .package(path: %s), .package(path: %s)
    ],
    targets: [.executableTarget(name: "WalletValidation", dependencies: [
        .product(name: "OathDatabase", package: "OathDatabase"),
        .product(name: "OathCloudBackup", package: "OathCloudBackup"),
        .product(name: "OathMarketData", package: "OathMarketData"),
        .product(name: "OathWalletHandoff", package: "OathWalletHandoff"),
        .product(name: "OathAezeed", package: "OathAezeed"),
        .product(name: "OathBitcoin", package: "OathBitcoin")
    ])], swiftLanguageModes: [.v6]
)
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathCloudBackup")), json.dumps(str(root / "Packages/OathMarketData")), json.dumps(str(root / "Packages/OathBitcoin")), json.dumps(str(root / "Packages/OathWalletHandoff")), json.dumps(str(root / "Packages/OathAezeed"))))
    environment = dict(os.environ, OATH_ELECTRUM_FIXTURES=str(root / "Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/electrum-reference.json"), OATH_AEZEED_FIXTURES=str(root / "Packages/OathAezeed/Tests/OathAezeedTests/Fixtures/lnd-production.json"), OATH_TEST_WORDLISTS=str(root / "OathApp/Resources/BIP39"), OATH_OVERLAP_FIXTURE=str(root / "Tools/Fixtures/RecoveryFormatOverlap.json"),
                       OATH_TEST_LITECOIN_VECTORS=str(root / "Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/litecoin-vectors.json"),
                       OATH_TEST_DOGECOIN_VECTORS=str(root / "Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/dogecoin-vectors.json"))
    subprocess.run(["swift", "run", "--build-system", "native", "--package-path", str(work),
                    "--scratch-path", os.environ.get("OATH_VALIDATION_SCRATCH", "/tmp/oath-multiwallet-validation-build"), "WalletValidation"], check=True, env=environment)
