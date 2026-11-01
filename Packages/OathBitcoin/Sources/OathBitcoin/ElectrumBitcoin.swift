import Foundation
import CryptoKit
import OathSecp256k1
import OathDiagnostics
internal import BitcoinDevKit

public enum ElectrumBitcoin {
    public static func wallet(_ material: ElectrumSeedMaterial) throws -> BitcoinWalletDescriptor {
        guard material.isValid else { throw ElectrumMnemonicError.invalidPhrase }
        if material.kind == .old {
            let pub = try OathSecp256k1.publicKey(material.seed, compressed: false)
            return .init(branches: [0,1].map { change in
                .init(type: .legacy, change: change, path: "electrum/\(change)", descriptor: "pkh(\(pub.hex))", isHD: true, electrumLegacyPublicKey: pub)
            }, defaultType: .legacy, scopedImport: true)
        }
        let roots = try roots(material)
        let type: BitcoinAddressType = material.kind == .segwit || material.kind == .twoFactorSegwit ? .nativeSegwit : .legacy
        let branches = try [UInt32(0),1].map { change in
            let keys = roots.map { $0.asPublic().description + "/\(change)/*" }
            let expressions = material.kind.isTwoFactor ? keys + [try thirdKey(material, roots: roots) + "/\(change)/*"] : keys
            let descriptor = try checkedDescriptor(material.kind, expressions)
            return BitcoinBranch(type: type, change: change, path: "electrum/\(change)", descriptor: descriptor.asPublic().description, isHD: true)
        }
        return .init(branches: branches, defaultType: type, scopedImport: true)
    }
    static func legacyAddresses(branch: BitcoinBranch, range: Range<UInt32>) throws -> [BitcoinDerivedAddress] {
        guard let pub = branch.electrumLegacyPublicKey, pub.count == 65, pub.first == 4,
              branch.network == .bitcoin, branch.type == .legacy, branch.change <= 1,
              branch.path == "electrum/\(branch.change)", branch.descriptor == "pkh(\(pub.hex))", branch.isHD else { throw BitcoinError.invalidAddress }
        return try range.map { index in
            try Task.checkCancellation()
            let leaf = try OathSecp256k1.adding(legacyTweak(pub, change: branch.change, index: index), toPublicKey: pub, compressed: false)
            let descriptor = try Descriptor(descriptor: "pkh(\(leaf.hex))", networkKind: .main)
            let address = try descriptor.deriveAddress(index: 0, network: .bitcoin)
            let script = address.scriptPubkey().toBytes()
            return .init(branchID: branch.id, type: .legacy, change: branch.change, index: index,
                path: "\(branch.path)/\(index)", address: address.description, script: script.hex,
                scriptHash: Data(SHA256.hash(data: script).reversed()).hex)
        }
    }
    private static func legacyTweak(_ pub: Data, change: UInt32, index: UInt32) -> Data {
        Data(SHA256.hash(data: Data(SHA256.hash(data: Data("\(index):\(change):".utf8) + pub.dropFirst()))))
    }
    public static func privateKey(_ material: ElectrumSeedMaterial, address: BitcoinDerivedAddress) throws -> String {
        guard !material.kind.isTwoFactor else { throw BitcoinError.unsupportedKeyScope }
        try validate(address, wallet: wallet(material))
        if material.kind == .old {
            let pub = try OathSecp256k1.publicKey(material.seed, compressed: false)
            var bytes = try OathSecp256k1.adding(legacyTweak(pub, change: address.change, index: address.index), toSecretKey: material.seed)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return try BitcoinKeys.wif(bytes: bytes, compressed: false)
        }
        return try leafWIF(roots(material)[0], address: address)
    }
    public static func sign(_ plan: BitcoinSendPlan, material: ElectrumSeedMaterial) throws -> BitcoinSignedSend {
        do {
            guard plan.chain == .bitcoin else { throw BitcoinError.wrongNetwork }
            let policy = try wallet(material)
            try validate(plan.change, wallet: policy)
            if !material.kind.isTwoFactor { return try BitcoinSendSigner.sign(plan) { _ in .electrum(material) } }
            let roots = try roots(material)
            let third = try DescriptorPublicKey.fromString(publicKey: thirdKey(material, roots: roots))
            return try BitcoinSendSigner.signWithDescriptors(plan) { coin in
                try validate(coin.address, wallet: policy)
                let keys = try roots.map { try leafWIF($0, address: coin.address) }
                let thirdLeaf = try third.derive(path: DerivationPath(path: "m/\(coin.address.change)/\(coin.address.index)")).description
                return try checkedDescriptor(material.kind, keys + [thirdLeaf])
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Descriptor libraries may include key expressions in errors. Only a stable code leaves this boundary.
            OathDiagnostics.record(DiagnosticFailure("electrum_signing_failed"), component: "bitcoin", operation: "electrum_sign", context: ["chain": "bitcoin"])
            throw BitcoinSendError.signing
        }
    }
    private static func validate(_ address: BitcoinDerivedAddress, wallet: BitcoinWalletDescriptor) throws {
        guard address.index < BitcoinKeys.firstHardenedChild, let branch = wallet.branches.first(where: { $0.id == address.branchID }),
              try BitcoinKeys.addresses(branch: branch, range: address.index..<(address.index+1)).first == address else { throw BitcoinError.invalidAddress }
    }
    private static func leafWIF(_ root: DescriptorSecretKey, address: BitcoinDerivedAddress) throws -> String {
        var bytes = try root.derive(path: DerivationPath(path: "m/\(address.change)/\(address.index)")).secretBytes()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try BitcoinKeys.wif(bytes: bytes, compressed: true)
    }
    private static func roots(_ material: ElectrumSeedMaterial) throws -> [DescriptorSecretKey] {
        guard material.isValid, material.kind != .old else { throw ElectrumMnemonicError.invalidPhrase }
        func root(_ seed: Data, path: String) throws -> DescriptorSecretKey {
            var digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
            defer { digest.resetBytes(in: 0..<digest.count) }
            var payload = Data([0x04,0x88,0xad,0xe4]) + Data(repeating: 0, count: 9) + digest.suffix(32) + Data([0]) + digest.prefix(32)
            defer { payload.resetBytes(in: 0..<payload.count) }
            return try DescriptorSecretKey.fromString(privateKey: Base58Check.encode(payload)).derive(path: DerivationPath(path: path))
        }
        if let second = material.secondSeed { return try [root(material.seed, path: "m"), root(second, path: "m")] }
        if material.kind.isTwoFactor { return try [root(material.seed, path: "m/0'"), root(material.seed, path: "m/1'")] }
        return try [root(material.seed, path: material.kind == .segwit ? "m/0'" : "m")]
    }
    private static func thirdKey(_ material: ElectrumSeedMaterial, roots: [DescriptorSecretKey]) throws -> String {
        // TrustedCoin identity hashes canonical xpub/Zpub SERIALIZATIONS (no origins).
        let pubs = try roots.map { root -> String in
            let expression = root.asPublic().description
            let plain = String(expression.split(separator: "]").last!)
            var payload = try Base58Check.decode(plain)
            if material.kind == .twoFactorSegwit { payload.replaceSubrange(0..<4, with: [0x02,0xaa,0x7e,0xd3]) }
            return Base58Check.encode(payload)
        }
        let identity = Data(SHA256.hash(data: Data(pubs.sorted().joined().utf8)))
        let server = try Base58Check.decode("xpub661MyMwAqRbcGnMkaTx2594P9EDuiEqMq25PM2aeG6UmwzaohgA6uDmNsvSUV8ubqwA3Wpste1hg69XHgjUuCD5HLcEp2QPzyV1HMrPppsL")
        let digest = Data(HMAC<SHA512>.authenticationCode(for: server.suffix(33) + identity, using: SymmetricKey(data: server[13..<45])))
        let pub = try OathSecp256k1.adding(Data(digest.prefix(32)), toPublicKey: Data(server.suffix(33)))
        return Base58Check.encode(Data([0x04,0x88,0xb2,0x1e]) + Data(repeating: 0, count: 9) + digest.suffix(32) + pub)
    }
    private static func checkedDescriptor(_ kind: ElectrumSeedKind, _ keys: [String]) throws -> Descriptor {
        let text: String
        if kind.isTwoFactor { text = "\(kind == .twoFactorSegwit ? "wsh" : "sh")(sortedmulti(2,\(keys.joined(separator: ","))))" }
        else { text = "\(kind == .segwit ? "wpkh" : "pkh")(\(keys[0]))" }
        let descriptor = try Descriptor(descriptor: text, networkKind: .main)
        try descriptor.sanityCheck()
        return descriptor
    }
}
