import Foundation
import WalletCore
import OathBitcoin
import OathCloudBackup

extension BackupWallet.BitcoinMultisig {
    var utxoNetwork: UTXONetwork { chainID == "dogecoin" ? .dogecoin : chainID == "bitcoincash" ? .bitcoincash : chainID == "litecoin" ? .litecoin : .bitcoin }
    func signingKeys() throws -> [BitcoinMultisigKey] {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return try signers.map { signer in
            if let wif = signer.wif {
                try BitcoinMultisig.validateWIF(wif, network: utxoNetwork)
                return .wif(wif)
            }
            guard let phrase = signer.mnemonic, let language = signer.language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(phrase), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try signer.passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false) else {
                throw OathWalletError.invalidPhrase
            }
            return .seed(wallet.seed)
        }
    }

    func descriptor() throws -> BitcoinWalletDescriptor {
        try BitcoinMultisig.wallet(required: required, keys: signingKeys(), network: utxoNetwork)
    }

    /// Portable, explicit recovery export including policy and all signer material.
    /// This is shown only after fresh authentication or copied by an explicit action.
    var recoveryText: String {
        var lines = ["Oath \(chainID == "dogecoin" ? "Dogecoin" : chainID == "bitcoincash" ? "Bitcoin Cash" : chainID == "litecoin" ? "Litecoin" : "Bitcoin") multisig v\(version)", "Policy: \(["bitcoincash", "dogecoin"].contains(chainID) ? "sh(sortedmulti)" : "wsh(sortedmulti)")",
                     "Required signatures: \(required) of \(signers.count)",
                     "BIP39 derivation: \(accountPath)/change/index", ""]
        for (index, signer) in signers.enumerated() {
            lines.append("Key \(index + 1)")
            if let wif = signer.wif { lines.append("WIF: " + wif) }
            if let phrase = signer.mnemonic {
                lines.append("BIP39: " + phrase)
                // JSON quoting makes leading/trailing whitespace and newlines unambiguous.
                let quoted = String(decoding: try! JSONEncoder().encode(signer.passphrase ?? ""), as: UTF8.self)
                lines.append("BIP39 passphrase (JSON string): " + quoted)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.BitcoinMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        _ = try material.descriptor()
        return OathWalletSecret(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false,
                                bitcoinMultisig: material)
    }

    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.BitcoinMultisig) throws -> OathWalletProfile {
        let descriptor = try material.descriptor()
        guard let branch = descriptor.branches.first else { throw OathWalletError.derivationFailed }
        let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
        return .init(id: secret.id, addresses: [.init(chain: material.chainID == "dogecoin" ? .dogecoin : material.chainID == "bitcoincash" ? .bitcoincash : material.chainID == "litecoin" ? .litecoin : .bitcoin, address: address.address,
            path: material.accountPath + "/0/0")], createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
