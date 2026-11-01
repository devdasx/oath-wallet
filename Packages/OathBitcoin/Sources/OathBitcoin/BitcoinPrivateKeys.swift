import Foundation
import CryptoKit
internal import BitcoinDevKit

/// Sources never leave the vault. The public descriptor and selected address
/// are rederived before returning one leaf WIF, never an HD parent private key.
public enum BitcoinPrivateKeySource: Sendable {
    case seed(Data, account: UInt32)
    case aezeed(Data, account: UInt32)
    case electrum(ElectrumSeedMaterial)
    case extended(String)
    case single(Data, compressed: Bool)
}

extension UTXONetwork {
    public func privateKeyWIF(source: BitcoinPrivateKeySource, address: BitcoinDerivedAddress) throws -> String {
        try Task.checkCancellation()
        let wallet: BitcoinWalletDescriptor
        let root: String?
        switch source {
        case .electrum(let material):
            guard self == .bitcoin else { throw BitcoinError.wrongNetwork }
            return try ElectrumBitcoin.privateKey(material, address: address)
        case .seed(let seed, let account), .aezeed(let seed, let account):
            if case .aezeed = source {
                guard self == .bitcoin else { throw BitcoinError.wrongNetwork }
                wallet = try BitcoinKeys.aezeedWallet(entropy: seed, account: account)
            } else { wallet = try self.wallet(seed: seed, account: account) }
            var digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
            defer { digest.resetBytes(in: 0..<digest.count) }
            var payload = Data([0x04, 0x88, 0xad, 0xe4]) + Data(repeating: 0, count: 9) + digest.suffix(32) + Data([0]) + digest.prefix(32)
            defer { payload.resetBytes(in: 0..<payload.count) }
            root = Base58Check.encode(payload)
        case .extended(let text):
            wallet = try extended(text)
            // The network decoder rejects public keys and wrong prefixes before
            // normalization to BDK's mainnet private extended-key encoding.
            let decoded = try decodeImport(text)
            guard decoded.extended != nil else { throw BitcoinError.invalidKey }
            var payload = try Base58Check.decode(text)
            defer { payload.resetBytes(in: 0..<payload.count) }
            guard payload.count == 78, payload[45] == 0 else { throw BitcoinError.invalidKey }
            payload.replaceSubrange(0..<4, with: [0x04, 0x88, 0xad, 0xe4])
            root = Base58Check.encode(payload)
        case .single(let bytes, let compressed):
            wallet = try singleKey(bytes: bytes, compressed: compressed)
            root = nil
        }
        guard let branch = wallet.branches.first(where: { $0.id == address.branchID }),
              address.index < BitcoinKeys.firstHardenedChild,
              try BitcoinKeys.addresses(branch: branch, range: address.index..<(address.index + 1)).first == address else {
            throw BitcoinError.invalidAddress
        }
        if case .single(let bytes, let compressed) = source {
            return try wif(bytes: bytes, compressed: compressed)
        }
        guard let root else { throw BitcoinError.invalidKey }
        let path = address.path.hasPrefix("imported") ? "m" + address.path.dropFirst("imported".count) : address.path
        let key = try DescriptorSecretKey.fromString(privateKey: root).derive(path: DerivationPath(path: path))
        var bytes = key.secretBytes()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        // Check the actual leaf public key in the chosen script, including the
        // BIP86 internal key for Taproot and network-specific address encoding.
        let leaf = try singleKey(bytes: bytes, compressed: true)
        guard let leafBranch = leaf.branches.first(where: { $0.type == address.type }),
              try BitcoinKeys.addresses(branch: leafBranch, range: 0..<1).first?.address == address.address else {
            throw BitcoinError.invalidAddress
        }
        try Task.checkCancellation()
        return try wif(bytes: bytes, compressed: true)
    }
}
