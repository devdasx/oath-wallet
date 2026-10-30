import Foundation
import OathWalletHandoff
import OathCloudBackup
import OathBitcoin
import OathAezeed

extension OathRestoredWallet {
    /// Reuses the existing validated restore/commit path. A public address must
    /// agree with the recovered key before any local wallet is committed.
    init(handoff: WalletHandoff, requestID: UUID, validator: OathMnemonicValidator? = .bundled) throws {
        try handoff.validate()
        let accounts = try handoff.accounts.map { a -> (OathImportChain, WalletHandoff.Account) in
            guard let chain = OathImportChain.allCases.first(where: { $0.handoffNetworkID == a.networkID || $0.rawValue == a.networkID }) else {
                throw HandoffError.invalid
            }
            return (chain, a)
        }
        guard Set(accounts.map { $0.0.id + ":" + String($0.1.accountIndex) }).count == accounts.count else { throw HandoffError.invalid }
        if let scheme = handoff.recoveryScheme, scheme != "bip39" {
            let phrase: OathValidatedMnemonic
            if scheme == "aezeed" {
                let material = try Aezeed.decode(handoff.value, passphrase: handoff.passphrase ?? "")
                phrase = .init(phrase: Aezeed.canonical(handoff.value), language: "english", aezeed: material)
            } else {
                let kinds: [String: ElectrumSeedKind] = ["electrumOld": .old, "electrumStandard": .standard,
                    "electrumSegwit": .segwit, "electrumTwoFactor": .twoFactor, "electrumTwoFactorSegwit": .twoFactorSegwit]
                let material = try ElectrumMnemonic.decode(handoff.value, passphrase: handoff.passphrase ?? "")
                guard kinds[scheme] == material.kind else { throw HandoffError.invalid }
                phrase = .init(phrase: ElectrumMnemonic.normalize(handoff.value), language: "electrum", electrum: material)
            }
            var secret = try OathWalletEngine.imported(phrase, id: requestID)
            secret.createdWithCustomization = true
            let profile = try OathWalletEngine.profile(for: secret)
            guard accounts.count == 1, accounts[0].0 == .bitcoin,
                  profile.addresses.count == 1, profile.addresses[0].address == accounts[0].1.address,
                  profile.addresses[0].path == accounts[0].1.derivationPath else { throw HandoffError.invalid }
            self.secret = secret; self.profile = profile
            return
        }
        let key: OathImportedPrivateKey?
        let phrase: OathValidatedMnemonic?
        switch handoff.kind {
        case .recoveryPhrase:
            guard let verified = validator?.verifiedPhrase(handoff.value) else { throw HandoffError.invalid }
            phrase = verified; key = nil
        case .privateKey:
            phrase = nil
            let networks = accounts.map { $0.0 }
            guard Set(networks).count == networks.count, accounts.allSatisfy({ $0.1.accountIndex == 0 }),
                  networks.allSatisfy(\.isEVM) || networks.count == 1 else { throw HandoffError.invalid }
            if let declared = handoff.importNetworkID {
                guard declared == "evm" ? networks.allSatisfy(\.isEVM) :
                    (networks.count == 1 && (networks[0].handoffNetworkID == declared || networks[0].id == declared)) else {
                    throw HandoffError.invalid
                }
            }
            if let bytes = handoff.rawKey {
                let marker = accounts[0].1.derivationPath
                // The old payload cannot reconstruct a BIP32 chain code from a
                // scalar. Reject such a record instead of importing another wallet.
                guard !marker.contains("extended") else { throw HandoffError.invalid }
                key = .init(bytes: bytes, networks: networks,
                            compressed: marker == "private-key:wifUncompressed" ? false : nil)
            } else {
                let choice = OathPrivateKeyChoice(id: networks.allSatisfy(\.isEVM) ? "evm" : networks[0].id,
                                                  title: "", networks: networks)
                key = try OathWalletEngine.importedPrivateKey(handoff.value, choice: choice)
            }
        case .bitcoinImportedWallet:
            // Legacy collections/descriptors are not a single key. The modern
            // wallet must never silently drop sources, branches or script types.
            throw HandoffError.unsupportedFormat
        }
        let importedKey = key.map { BackupWallet.ImportedPrivateKey(bytes: $0.bytes, networks: $0.networks.map(\.id),
            compressed: $0.compressed, bitcoinExtendedKey: $0.bitcoinExtendedKey, dogecoinExtendedKey: $0.dogecoinExtendedKey,
            litecoinExtendedKey: $0.litecoinExtendedKey, bitcoinCashExtendedKey: $0.bitcoinCashExtendedKey) }
        let backup = BackupWallet(id: requestID, name: "", mnemonic: phrase?.phrase ?? "", language: phrase?.language ?? "",
            createdAt: .now, accounts: accounts.map { chain, account in
                .init(network: chain.id, derivationPath: key != nil ? "imported" : account.derivationPath, index: account.accountIndex)
            }, privateKey: importedKey, passphrase: handoff.passphrase?.isEmpty == false ? handoff.passphrase : nil,
            legacyPassphrase: handoff.passphrase?.isEmpty == false ? true : nil)
        let restored = try OathRestoredWallet(backup: backup, validator: validator)
        for (chain, expected) in accounts {
            guard let actual = restored.profile.addresses.first(where: { $0.chain == chain && $0.accountIndex == expected.accountIndex }),
                  chain.isEVM ? actual.address.lowercased() == expected.address.lowercased() : actual.address == expected.address else {
                throw HandoffError.invalid
            }
        }
        var secret = restored.secret
        secret.createdWithCustomization = true
        self.secret = secret
        self.profile = restored.profile
    }
}

extension OathImportChain {
    var handoffNetworkID: String {
        switch self {
        case .ethereum: "eth"
        case .bnb: "bsc"
        case .bitcoincash: "bitcoin_cash"
        case .xrpl: "xrp"
        default: rawValue
        }
    }
}
