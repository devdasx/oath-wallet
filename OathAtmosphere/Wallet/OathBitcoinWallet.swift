import Foundation
import WalletCore
import OathBitcoin
import OathCloudBackup
import OathDatabase

extension OathImportedPrivateKey {
    func extendedKey(for network: UTXONetwork) -> String? {
        switch network {
        case .bitcoin: bitcoinExtendedKey
        case .dogecoin: dogecoinExtendedKey
        case .litecoin: litecoinExtendedKey
        case .bitcoincash: bitcoinCashExtendedKey
        }
    }

    func bitcoinDescriptor() throws -> BitcoinWalletDescriptor {
        guard isValidStructure, networks.count == 1,
              let network = UTXONetwork(rawValue: networks[0].id) else { throw OathWalletError.invalidPrivateKey }
        if let extended = extendedKey(for: network) {
            let decoded = try network.decodeImport(extended)
            guard decoded.bytes == bytes else { throw OathWalletError.invalidPrivateKey }
            return try network.extended(extended)
        }
        return try network.singleKey(bytes: bytes, compressed: compressed != false)
    }
}

extension OathWalletEngine {
    static func signBitcoin(_ plan: BitcoinSendPlan, secret: OathWalletSecret, accounts: [AccountRecord]) throws -> BitcoinSignedSend {
        var seed: Data?
        defer { if seed != nil { seed!.resetBytes(in: 0..<seed!.count) } }
        if secret.privateKey == nil {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false) else { throw OathWalletError.derivationFailed }
            seed = wallet.seed
        }
        let source: (String) throws -> BitcoinPrivateKeySource = { accountID in
            guard let account = accounts.first(where: { $0.id == accountID }), account.walletID == secret.id.uuidString,
                  account.networkID == plan.chain.rawValue, account.accountIndex >= 0, account.accountIndex < 0x8000_0000 else { throw BitcoinSendError.invalidInput }
            if let material = secret.privateKey {
                guard material.isValidStructure, material.networks.map(\.rawValue) == [plan.chain.rawValue] else { throw BitcoinSendError.invalidInput }
                if let extended = material.extendedKey(for: plan.chain) {
                    guard try plan.chain.decodeImport(extended).bytes == material.bytes else { throw BitcoinSendError.invalidInput }
                    return .extended(extended)
                }
                return .single(material.bytes, compressed: material.compressed != false)
            }
            guard let seed else { throw BitcoinSendError.signing }
            return .seed(seed, account: UInt32(account.accountIndex))
        }
        if plan.chain == .bitcoincash { return try BitcoinCashSendSigner.sign(plan, source: source) }
        return try BitcoinSendSigner.sign(plan, source: source)
    }
    static func bitcoinDescriptor(for secret: OathWalletSecret, account: UInt32, network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        if let key = secret.privateKey {
            let descriptor = try key.bitcoinDescriptor()
            guard descriptor.network == network else { throw OathWalletError.invalidPrivateKey }
            return descriptor
        }
        let passphrase = try secret.bip39Passphrase
        guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
              let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false) else { throw OathWalletError.derivationFailed }
        var seed = wallet.seed
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try network.wallet(seed: seed, account: account)
    }
}
