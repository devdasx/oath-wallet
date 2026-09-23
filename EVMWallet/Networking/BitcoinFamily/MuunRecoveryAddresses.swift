import CryptoKit
import Foundation
import P256K
import WalletCore

enum MuunRecoveryAddressFactory {
    private static let keyAggListTag = Data("KeyAgg list".utf8)
    private static let keyAggCoefficientTag = Data(
        "KeyAgg coefficient".utf8
    )
    private static let tapTweakTag = Data("TapTweak".utf8)
    private static let scalarOne = Data(repeating: 0, count: 31) + Data([1])

    static func deriveAll(
        material: MuunRecoveryKeyMaterial,
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int? = nil,
        addressIndex: Int
    ) throws -> [MuunRecoveryDerivedAddress] {
        try MuunRecoveryAddressVersion.allCases.map {
            try derive(
                material: material,
                version: $0,
                branch: branch,
                contactIndex: contactIndex,
                addressIndex: addressIndex
            )
        }
    }

    static func derive(
        material: MuunRecoveryKeyMaterial,
        version: MuunRecoveryAddressVersion,
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int? = nil,
        addressIndex: Int
    ) throws -> MuunRecoveryDerivedAddress {
        let keys = try MuunRecoveryDerivation.keys(
            material: material,
            branch: branch,
            contactIndex: contactIndex,
            addressIndex: addressIndex
        )
        return try address(
            userPublicKey: keys.user.publicKey,
            muunPublicKey: keys.muun.publicKey,
            version: version,
            branch: branch,
            contactIndex: contactIndex,
            addressIndex: addressIndex,
            derivationPath: keys.derivationPath
        )
    }

    static func address(
        userPublicKey: Data,
        muunPublicKey: Data,
        version: MuunRecoveryAddressVersion,
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int?,
        addressIndex: Int,
        derivationPath: String
    ) throws -> MuunRecoveryDerivedAddress {
        guard userPublicKey.count == 33,
              muunPublicKey.count == 33 else {
            throw MuunRecoveryError.derivationFailed
        }
        let script: Data
        switch version {
        case .v2:
            let redeemScript = multisigScript(
                userPublicKey: userPublicKey,
                muunPublicKey: muunPublicKey
            )
            script = p2shScript(redeemScript)
        case .v3:
            let witnessScript = multisigScript(
                userPublicKey: userPublicKey,
                muunPublicKey: muunPublicKey
            )
            let redeemScript = Data([0x00, 0x20])
                + singleSHA256(witnessScript)
            script = p2shScript(redeemScript)
        case .v4:
            let witnessScript = multisigScript(
                userPublicKey: userPublicKey,
                muunPublicKey: muunPublicKey
            )
            script = Data([0x00, 0x20]) + singleSHA256(witnessScript)
        case .v5:
            let outputKey = try taprootOutputPublicKey(
                userPublicKey: userPublicKey,
                muunPublicKey: muunPublicKey
            )
            script = Data([0x51, 0x20]) + outputKey
        }
        guard let encodedAddress = BitcoinFamilyScriptAddress.address(
            from: script,
            chain: .bitcoin
        ), CoinType.bitcoin.validate(address: encodedAddress) else {
            throw MuunRecoveryError.derivationFailed
        }
        return MuunRecoveryDerivedAddress(
            version: version,
            branch: branch,
            contactIndex: contactIndex,
            addressIndex: addressIndex,
            derivationPath: derivationPath,
            address: encodedAddress,
            scriptPubKey: script,
            scriptHash: Data(singleSHA256(script).reversed()).hexString
        )
    }

    static func taprootOutputPrivateKey(
        userPrivateKey: Data,
        muunPrivateKey: Data
    ) throws -> Data {
        var user = try evenPrivateKey(userPrivateKey)
        var muun = try evenPrivateKey(muunPrivateKey)
        let coefficients = try aggregationCoefficients(
            userPublicKey: user.publicKey,
            muunPublicKey: muun.publicKey
        )
        user = try user.multiply(Array(coefficients.user))
        muun = try muun.multiply(Array(coefficients.muun))
        var aggregate = try user.add(Array(muun.dataRepresentation))
        if aggregate.publicKey.dataRepresentation.first == 0x03 {
            aggregate = aggregate.negation
        }
        let tweak = try MuunSecp256k1Scalar.reduced(taggedHash(
            tag: tapTweakTag,
            message: Data(aggregate.publicKey.xonly.bytes)
        ))
        var output = try aggregate.add(Array(tweak))
        if output.publicKey.dataRepresentation.first == 0x03 {
            output = output.negation
        }
        return output.dataRepresentation
    }

    static func multisigScript(
        userPublicKey: Data,
        muunPublicKey: Data
    ) -> Data {
        Data([0x52, 0x21]) + userPublicKey
            + Data([0x21]) + muunPublicKey
            + Data([0x52, 0xae])
    }

    private static func taprootOutputPublicKey(
        userPublicKey: Data,
        muunPublicKey: Data
    ) throws -> Data {
        let user = try evenPublicKey(userPublicKey)
        let muun = try evenPublicKey(muunPublicKey)
        let coefficients = try aggregationCoefficients(
            userPublicKey: user,
            muunPublicKey: muun
        )
        let scaledUser = try user.multiply(Array(coefficients.user))
        let scaledMuun = try muun.multiply(Array(coefficients.muun))
        var aggregate = try scaledUser.combine([scaledMuun])
        if aggregate.dataRepresentation.first == 0x03 {
            aggregate = aggregate.negation
        }
        let tweak = try MuunSecp256k1Scalar.reduced(taggedHash(
            tag: tapTweakTag,
            message: Data(aggregate.xonly.bytes)
        ))
        let output = try aggregate.add(Array(tweak))
        return Data(output.xonly.bytes)
    }

    private static func aggregationCoefficients(
        userPublicKey: P256K.Signing.PublicKey,
        muunPublicKey: P256K.Signing.PublicKey
    ) throws -> (user: Data, muun: Data) {
        let userX = Data(userPublicKey.xonly.bytes)
        let muunX = Data(muunPublicKey.xonly.bytes)
        let keyListHash = taggedHash(
            tag: keyAggListTag,
            message: userX + muunX
        )
        let secondDistinct = userX == muunX ? nil : muunX
        func coefficient(for x: Data) throws -> Data {
            if x == secondDistinct { return scalarOne }
            return try MuunSecp256k1Scalar.reduced(taggedHash(
                tag: keyAggCoefficientTag,
                message: keyListHash + x
            ))
        }
        return (try coefficient(for: userX), try coefficient(for: muunX))
    }

    private static func evenPublicKey(
        _ data: Data
    ) throws -> P256K.Signing.PublicKey {
        let key = try P256K.Signing.PublicKey(
            dataRepresentation: data,
            format: .compressed
        )
        return data.first == 0x03 ? key.negation : key
    }

    private static func evenPrivateKey(
        _ data: Data
    ) throws -> P256K.Signing.PrivateKey {
        let key = try P256K.Signing.PrivateKey(
            dataRepresentation: data
        )
        return key.publicKey.dataRepresentation.first == 0x03
            ? key.negation
            : key
    }

    private static func p2shScript(_ redeemScript: Data) -> Data {
        Data([0xa9, 0x14]) + Hash.sha256RIPEMD(data: redeemScript)
            + Data([0x87])
    }

    private static func singleSHA256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    private static func taggedHash(tag: Data, message: Data) -> Data {
        let tagHash = singleSHA256(tag)
        return singleSHA256(tagHash + tagHash + message)
    }
}
