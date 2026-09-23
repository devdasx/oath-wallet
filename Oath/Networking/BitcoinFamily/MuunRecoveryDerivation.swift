import Foundation
import P256K

struct MuunRecoveryFingerprints: Equatable, Sendable {
    let user: String
    let muun: String

    init(user: String, muun: String) throws {
        let normalizedUser = user.lowercased()
        let normalizedMuun = muun.lowercased()
        guard Self.isFingerprint(normalizedUser),
              Self.isFingerprint(normalizedMuun) else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        self.user = normalizedUser
        self.muun = normalizedMuun
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 8 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 97...102: true
            default: false
            }
        }
    }
}

struct MuunRecoveryDerivedKeyPair: Sendable {
    let user: ElectrumBIP32Node
    let muun: ElectrumBIP32Node
    let derivationPath: String
}

enum MuunRecoveryDerivation {
    static func verify(
        material: MuunRecoveryKeyMaterial,
        expectedFingerprints: MuunRecoveryFingerprints
    ) throws {
        let roots = try roots(material: material)
        let muunBase = try roots.muun
            .derived(at: 0x8000_0001)
            .derived(at: 0x8000_0001)
        let actual = try MuunRecoveryFingerprints(
            user: fingerprintHex(roots.user.fingerprint),
            muun: fingerprintHex(muunBase.fingerprint)
        )
        guard actual == expectedFingerprints else {
            throw MuunRecoveryError.recoveryCodeDoesNotMatchEmergencyKit
        }
    }

    static func keys(
        material: MuunRecoveryKeyMaterial,
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int? = nil,
        addressIndex: Int
    ) throws -> MuunRecoveryDerivedKeyPair {
        guard addressIndex >= 0,
              addressIndex <= Int(UInt32.max),
              (branch == .contacts) == (contactIndex != nil),
              contactIndex.map({ $0 >= 0 && $0 <= Int(UInt32.max) }) ?? true
        else {
            throw MuunRecoveryError.invalidDerivationPath
        }
        let roots = try roots(material: material)
        var user = roots.user
        var muun = roots.muun
        muun = try muun.derived(at: 0x8000_0001)
        muun = try muun.derived(at: 0x8000_0001)
        user = try user.derived(at: UInt32(branch.rawValue))
        muun = try muun.derived(at: UInt32(branch.rawValue))

        var components = ["m", "1'", "1'", String(branch.rawValue)]
        if let contactIndex {
            user = try user.derived(at: UInt32(contactIndex))
            muun = try muun.derived(at: UInt32(contactIndex))
            components.append(String(contactIndex))
        }
        user = try user.derived(at: UInt32(addressIndex))
        muun = try muun.derived(at: UInt32(addressIndex))
        components.append(String(addressIndex))
        return MuunRecoveryDerivedKeyPair(
            user: user,
            muun: muun,
            derivationPath: components.joined(separator: "/")
        )
    }

    static func roots(
        material: MuunRecoveryKeyMaterial
    ) throws -> (user: ElectrumBIP32Node, muun: ElectrumBIP32Node) {
        let material = try material.validated()
        return (
            try node(
                privateKey: material.userPrivateKey,
                chainCode: material.userChainCode
            ),
            try node(
                privateKey: material.muunPrivateKey,
                chainCode: material.muunChainCode
            )
        )
    }

    private static func node(
        privateKey: Data,
        chainCode: Data
    ) throws -> ElectrumBIP32Node {
        do {
            let key = try P256K.Signing.PrivateKey(
                dataRepresentation: privateKey
            )
            return ElectrumBIP32Node(
                privateKey: privateKey,
                publicKey: key.publicKey.dataRepresentation,
                chainCode: chainCode,
                depth: 0,
                parentFingerprint: 0,
                childNumber: 0
            )
        } catch {
            throw MuunRecoveryError.invalidKeyMaterial
        }
    }

    private static func fingerprintHex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }
}
