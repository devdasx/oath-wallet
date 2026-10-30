import Foundation
import OathCloudBackup
import OathDatabase

/// Kept in the encrypted vault so recovery of an interrupted SQL commit also
/// recovers the backup's customization and exact account paths.
struct OathWalletRestorationMetadata: Codable, Sendable {
    let name: String
    let colorHex: String?
    let accounts: [BackupWallet.Account]
    var legacyPassphrase: Bool? = nil
}

/// Prepared off the UI thread. Only validated recovery material and derived
/// public addresses can reach the vault's atomic restore operation.
struct OathRestoredWallet: Sendable {
    let secret: OathWalletSecret
    let profile: OathWalletProfile

    init(backup: BackupWallet, validator: OathMnemonicValidator? = .bundled) throws {
        try Task.checkCancellation()
        guard backup.name.count <= 100, backup.createdAt.timeIntervalSince1970.isFinite,
              !backup.accounts.isEmpty, backup.accounts.count <= 1_024,
              backup.colorHex == nil || (backup.colorHex!.count == 6 &&
                backup.colorHex!.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) })) else {
            throw CloudBackupError.invalidDocument
        }
        var accountIDs = Set<String>()
        for account in backup.accounts {
            guard OathImportChain(rawValue: account.network) != nil,
                  account.index >= 0, account.index < 2_147_483_648,
                  accountIDs.insert(account.network + ":" + String(account.index)).inserted else {
                throw CloudBackupError.invalidDocument
            }
            if backup.evmMultisig != nil {
                guard backup.accounts.count == 1, account.network == backup.evmMultisig?.network, account.index == 0,
                      account.derivationPath == "evm-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.tonMultisig != nil {
                guard backup.accounts.count == 1, account.network == "ton", account.index == 0,
                      account.derivationPath == "ton-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.thorchainMultisig != nil {
                guard backup.accounts.count == 1, account.network == "thorchain", account.index == 0,
                      account.derivationPath == "thorchain-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.nearMultisig != nil {
                guard backup.accounts.count == 1, account.network == "near", account.index == 0,
                      account.derivationPath == "near-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.suiMultisig != nil {
                guard backup.accounts.count == 1, account.network == "sui", account.index == 0,
                      account.derivationPath == "sui-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.aptosMultisig != nil {
                guard backup.accounts.count == 1, account.network == "aptos", account.index == 0,
                      account.derivationPath == "aptos-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.stellarMultisig != nil {
                guard backup.accounts.count == 1, account.network == "stellar", account.index == 0,
                      account.derivationPath == "stellar-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.xrplMultisig != nil {
                guard backup.accounts.count == 1, account.network == "xrpl", account.index == 0,
                      account.derivationPath == "xrpl-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if backup.solanaMultisig != nil {
                guard backup.accounts.count == 1, account.network == "solana", account.index == 0,
                      account.derivationPath == "solana-multisig-v1", account.solanaReceivePath == nil || account.solanaReceivePath == account.derivationPath else { throw CloudBackupError.invalidDocument }
            } else if backup.tronMultisig != nil {
                guard backup.accounts.count == 1, account.network == "tron", account.index == 0,
                      account.derivationPath == "tron-multisig-v1" else { throw CloudBackupError.invalidDocument }
            } else if let multisig = backup.bitcoinMultisig {
                guard backup.accounts.count == 1, account.network == multisig.chainID, account.index == 0,
                      account.derivationPath == multisig.accountPath + "/0/0" else { throw CloudBackupError.invalidDocument }
            } else if backup.privateKey != nil {
                guard account.derivationPath == "imported", account.index == 0 else { throw CloudBackupError.invalidDocument }
            } else {
                guard Self.validPath(account.derivationPath) else { throw CloudBackupError.invalidDocument }
            }
            if let path = account.solanaReceivePath {
                let index = SolanaDerivation.accountIndex(in: account.derivationPath) ?? account.index
                let paths = try SolanaDerivation.allCases.map { try $0.path(accountIndex: index) }
                guard backup.privateKey == nil, account.network == "solana",
                      paths.contains(path) || path == account.derivationPath else { throw CloudBackupError.invalidDocument }
            }
        }
        let material: OathImportedPrivateKey?
        let mnemonic: String
        if let multisig = backup.evmMultisig {
            guard multisig.isValidStructure, backup.tonMultisig == nil, backup.thorchainMultisig == nil, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil, backup.suiMultisig == nil, backup.aptosMultisig == nil, backup.nearMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.tonMultisig {
            guard multisig.isValidStructure, backup.thorchainMultisig == nil, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil, backup.suiMultisig == nil, backup.aptosMultisig == nil, backup.nearMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.thorchainMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil, backup.suiMultisig == nil, backup.aptosMultisig == nil, backup.nearMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.nearMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil, backup.suiMultisig == nil, backup.aptosMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.suiMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil, backup.aptosMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.aptosMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil, backup.stellarMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.stellarMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil, backup.xrplMultisig == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.xrplMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.solanaMultisig == nil, backup.privateKey == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.solanaMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.tronMultisig == nil, backup.privateKey == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.tronMultisig {
            guard multisig.isValidStructure, backup.bitcoinMultisig == nil, backup.privateKey == nil,
                  backup.passphrase == nil, backup.mnemonic.isEmpty, backup.language.isEmpty,
                  backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            try multisig.validateMaterial(); material = nil; mnemonic = ""
        } else if let multisig = backup.bitcoinMultisig {
            guard multisig.isValidStructure, backup.privateKey == nil, backup.passphrase == nil,
                  backup.mnemonic.isEmpty, backup.language.isEmpty, backup.legacyPassphrase == nil else { throw CloudBackupError.invalidDocument }
            _ = try multisig.descriptor()
            material = nil; mnemonic = ""
        } else if let key = backup.privateKey {
            let networks = key.networks.compactMap(OathImportChain.init(rawValue:))
            let imported = OathImportedPrivateKey(bytes: key.bytes, networks: networks, compressed: key.compressed, bitcoinExtendedKey: key.bitcoinExtendedKey, dogecoinExtendedKey: key.dogecoinExtendedKey, bitcoinCashExtendedKey: key.bitcoinCashExtendedKey, litecoinExtendedKey: key.litecoinExtendedKey)
            guard networks.count == key.networks.count, imported.isValidStructure,
                  Set(key.networks) == Set(backup.accounts.map(\.network)),
                  backup.mnemonic.isEmpty, backup.language.isEmpty, backup.passphrase == nil else {
                throw CloudBackupError.invalidDocument
            }
            material = imported
            mnemonic = ""
        } else {
            guard let phrase = validator?.verifiedPhrase(backup.mnemonic),
                  phrase.language == backup.language else { throw CloudBackupError.invalidDocument }
            material = nil
            mnemonic = phrase.phrase
        }
        guard backup.legacyPassphrase != true || (backup.privateKey == nil && backup.passphrase != nil) else { throw CloudBackupError.invalidDocument }
        let passphrase = try backup.passphrase.map {
            try backup.legacyPassphrase == true ? RecoveryPassphrase.normalizedLegacy($0) : RecoveryPassphrase.normalized($0)
        }
        let secret = OathWalletSecret(id: backup.id, mnemonic: mnemonic, language: backup.language,
            createdAt: backup.createdAt, backedUp: true, imported: true, createdWithCustomization: false,
            privateKey: material, passphrase: passphrase,
            parentWalletID: passphrase != nil && backup.parentWalletID != backup.id ? backup.parentWalletID : nil,
            // A new iCloud restore gets its own localized Restored Wallet name.
            // Keeping the automatic marker in ciphertext also survives SQL repair.
            restoration: .init(name: "", colorHex: backup.colorHex, accounts: backup.accounts, legacyPassphrase: backup.legacyPassphrase),
            bitcoinMultisig: backup.bitcoinMultisig, tronMultisig: backup.tronMultisig, solanaMultisig: backup.solanaMultisig, xrplMultisig: backup.xrplMultisig, evmMultisig: backup.evmMultisig, tonMultisig: backup.tonMultisig, thorchainMultisig: backup.thorchainMultisig, nearMultisig: backup.nearMultisig, suiMultisig: backup.suiMultisig, aptosMultisig: backup.aptosMultisig, stellarMultisig: backup.stellarMultisig)
        let profile = try OathWalletEngine.profile(for: secret)
        // SQL enforces one address per network per wallet. Reject conflicting
        // descriptors before the encrypted-vault commit, so a malformed backup
        // can never leave a wallet whose public metadata cannot be rebuilt.
        guard profile.addresses.count == backup.accounts.count,
              Set(profile.addresses.map { $0.chain.id + ":" + $0.address }).count == profile.addresses.count else {
            throw CloudBackupError.invalidDocument
        }
        self.profile = profile
        self.secret = secret
    }

    private static func validPath(_ path: String) -> Bool {
        guard path.utf8.count <= 128 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "m", (2...11).contains(components.count) else { return false }
        return components.dropFirst().allSatisfy { part in
            let digits = part.last == "'" ? part.dropLast() : part[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let index = UInt32(digits), index < 0x8000_0000 else { return false }
            return true
        }
    }
}

struct OathRestoredWalletSetupStore: OathPasscodeSaving {
    let vault: OathWalletVault
    let restoration: OathRestoredWallet
    func save(_ digits: [UInt8]) async throws {
        try await vault.createRestoredWallet(digits: digits, restoration: restoration)
    }
}
