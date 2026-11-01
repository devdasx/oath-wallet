import Foundation
import CryptoKit
import OathDiagnostics
internal import BitcoinDevKit

/// Secrets are supplied by the encrypted vault, never persisted in the public ledger.
public enum BitcoinMultisigKey: Sendable {
    case seed(Data)
    case wif(String)
}

public enum BitcoinMultisigError: String, Error, Sendable {
    case invalidThreshold, invalidKey, duplicateKey
}

/// BIP67 sorted keys: P2WSH for BTC/LTC, P2SH20 for DOGE and FORKID signing for BCH.
/// BIP39 seeds use the explicit chain-specific account-zero path exported in recovery.
/// WIF signers are fixed keys; mnemonic signers derive external/change children.
public enum BitcoinMultisig {
    public static let maximumKeys = 15
    public static let accountPath = "m/48'/0'/0'/2'"

    public static func accountPath(network: UTXONetwork) throws -> String {
        switch network {
        case .bitcoin: return accountPath
        case .litecoin: return "m/48'/2'/0'/2'"
        case .dogecoin: return "m/48'/3'/0'/0'"
        case .bitcoincash: return "m/48'/145'/0'/0'"
        }
    }

    public static func validateWIF(_ text: String, network: UTXONetwork = .bitcoin) throws {
        // All supported policies require compressed public keys. No hex, xpub, xprv or testnet aliases.
        _ = try accountPath(network: network)
        guard text.utf8.count == 52,
              let payload = try? Base58Check.decode(text),
              payload.count == 34, payload.last == 1,
              payload.first == (network == .dogecoin ? 0x9e : network == .litecoin ? 0xb0 : 0x80),
              var decoded = try? network.decodeImport(text) else { throw BitcoinMultisigError.invalidKey }
        defer { decoded.bytes.resetBytes(in: 0..<decoded.bytes.count) }
        guard decoded.compressed, decoded.extended == nil else { throw BitcoinMultisigError.invalidKey }
    }

    public static func wallet(required: Int, keys: [BitcoinMultisigKey], network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        do { return try makeWallet(required: required, keys: keys, network: network) }
        catch let error as BitcoinMultisigError {
            // diagnostics: multisig-form-validation; invalid threshold, duplicate signer or malformed key.
            throw error
        }
        catch let error as BitcoinError where error == .invalidKey || error == .unsupportedKeyScope {
            // diagnostics: multisig-form-validation; rejected key input is expected validation.
            throw error
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            // BDK errors can contain descriptor source. Never forward secret-bearing text.
            OathDiagnostics.record(DiagnosticFailure("multisig_descriptor_failed"),
                component: "bitcoin", operation: "multisig_descriptor", context: ["chain": network.rawValue])
            throw BitcoinMultisigError.invalidKey
        }
    }

    private static func makeWallet(required: Int, keys: [BitcoinMultisigKey], network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        let accountPath = try accountPath(network: network)
        let roots = try validatedRoots(required: required, keys: keys, network: network)
        let hd = keys.contains { if case .seed = $0 { return true }; return false }
        let branches = try (hd ? [UInt32(0), 1] : [UInt32(0)]).map { change in
            let expressions = try zip(roots, keys).map { root, key in
                switch key {
                case .seed:
                    return try root.derive(path: DerivationPath(path: accountPath)).asPublic().description + "/\(change)/*"
                case .wif: return root.asPublic().description
                }
            }
            let descriptor = try checkedDescriptor(required: required, expressions: expressions, network: network)
            return BitcoinBranch(type: [UTXONetwork.bitcoincash, .dogecoin].contains(network) ? .legacy : .nativeSegwit, change: change, path: accountPath + "/\(change)",
                descriptor: descriptor.asPublic().description, isHD: hd, network: network)
        }
        return .init(branches: branches, defaultType: [UTXONetwork.bitcoincash, .dogecoin].contains(network) ? .legacy : .nativeSegwit, scopedImport: true)
    }

    public static func sign(_ plan: BitcoinSendPlan, required: Int, keys: [BitcoinMultisigKey], network: UTXONetwork = .bitcoin) throws -> BitcoinSignedSend {
        do { return try signValidated(plan, required: required, keys: keys, network: network) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // The shared outbox receives only a stable code, never private descriptors.
            OathDiagnostics.record(DiagnosticFailure("multisig_signing_failed"),
                component: "bitcoin", operation: "multisig_sign", context: ["chain": network.rawValue])
            throw BitcoinSendError.signing
        }
    }

    private static func signValidated(_ plan: BitcoinSendPlan, required: Int, keys: [BitcoinMultisigKey], network: UTXONetwork = .bitcoin) throws -> BitcoinSignedSend {
        guard plan.chain == network else { throw BitcoinError.wrongNetwork }
        let policy = try wallet(required: required, keys: keys, network: network)
        let accountPath = try accountPath(network: network)
        let roots = try validatedRoots(required: required, keys: keys, network: network)
        func validate(_ address: BitcoinDerivedAddress) throws {
            guard address.index < BitcoinKeys.firstHardenedChild,
                  let branch = policy.branches.first(where: { $0.id == address.branchID }),
                  try BitcoinKeys.addresses(branch: branch, range: address.index..<(address.index + 1)).first == address else {
                throw BitcoinSendError.signing
            }
        }
        // Change must belong to this exact policy, not merely be a valid address.
        try validate(plan.change)
        if network == .bitcoincash {
            return try BitcoinCashMultisigSigner.sign(plan, required: required) { coin in
                try validate(coin.address)
                return try zip(roots, keys).map { root, key in
                    switch key {
                    case .wif(let text): return try network.decodeImport(text).bytes
                    case .seed:
                        return try root.derive(path: DerivationPath(path: accountPath + "/\(coin.address.change)/\(coin.address.index)")).secretBytes()
                    }
                }
            }
        }
        return try BitcoinSendSigner.signWithDescriptors(plan) { coin in
            try validate(coin.address)
            let expressions = try zip(roots, keys).map { root, key -> String in
                switch key {
                case .wif(let text):
                    var decoded = try network.decodeImport(text)
                    defer { decoded.bytes.resetBytes(in: 0..<decoded.bytes.count) }
                    return try BitcoinKeys.wif(bytes: decoded.bytes, compressed: true)
                case .seed:
                    let leaf = try root.derive(path: DerivationPath(path: accountPath + "/\(coin.address.change)/\(coin.address.index)"))
                    var bytes = leaf.secretBytes()
                    defer { bytes.resetBytes(in: 0..<bytes.count) }
                    return try BitcoinKeys.wif(bytes: bytes, compressed: true)
                }
            }
            return try checkedDescriptor(required: required, expressions: expressions, network: network)
        }
    }

    private static func validatedRoots(required: Int, keys: [BitcoinMultisigKey], network: UTXONetwork = .bitcoin) throws -> [DescriptorSecretKey] {
        let accountPath = try accountPath(network: network)
        guard (2...maximumKeys).contains(keys.count), (1...keys.count).contains(required) else { throw BitcoinMultisigError.invalidThreshold }
        let roots = try keys.map { key -> DescriptorSecretKey in
            switch key {
            case .wif(let text):
                try validateWIF(text, network: network)
                var decoded = try network.decodeImport(text)
                defer { decoded.bytes.resetBytes(in: 0..<decoded.bytes.count) }
                return try DescriptorSecretKey.fromString(privateKey: BitcoinKeys.wif(bytes: decoded.bytes, compressed: true))
            case .seed(let seed):
                guard (16...64).contains(seed.count) else { throw BitcoinMultisigError.invalidKey }
                var digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
                defer { digest.resetBytes(in: 0..<digest.count) }
                var payload = Data([0x04,0x88,0xad,0xe4]) + Data(repeating: 0, count: 9) + digest.suffix(32) + Data([0]) + digest.prefix(32)
                defer { payload.resetBytes(in: 0..<payload.count) }
                return try DescriptorSecretKey.fromString(privateKey: Base58Check.encode(payload))
            }
        }
        // Check actual leaf keys as well as roots: a WIF can alias an HD signer's first leaf.
        let leaves = try zip(roots, keys).map { root, key -> String in
            switch key {
            case .wif: return root.asPublic().description
            case .seed:
                let leaf = try root.derive(path: DerivationPath(path: accountPath + "/0/0"))
                var bytes = leaf.secretBytes()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                return try DescriptorSecretKey.fromString(privateKey: BitcoinKeys.wif(bytes: bytes, compressed: true)).asPublic().description
            }
        }
        guard Set(leaves).count == leaves.count else { throw BitcoinMultisigError.duplicateKey }
        return roots
    }

    private static func checkedDescriptor(required: Int, expressions: [String], network: UTXONetwork) throws -> Descriptor {
        let descriptor = try Descriptor(descriptor: "\([UTXONetwork.bitcoincash, .dogecoin].contains(network) ? "sh" : "wsh")(sortedmulti(\(required),\(expressions.joined(separator: ","))))", networkKind: .main)
        try descriptor.sanityCheck()
        return descriptor
    }
}
