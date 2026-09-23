import Foundation
import WalletCore

enum TONAddress {
    static func material(
        privateKey: PrivateKey,
        derivationPath: String?
    ) throws -> TONAccountMaterial {
        let publicKey = privateKey.getPublicKeyEd25519()
        let address = AnyAddress(
            publicKey: publicKey,
            coin: .ton
        ).description
        guard CoinType.ton.validate(address: address),
              let raw = rawAddress(from: address),
              let bounceable = TONAddressConverter.toUserFriendly(
                address: raw,
                bounceable: true,
                testnet: false
              ),
              let nonBounceable = TONAddressConverter.toUserFriendly(
                address: raw,
                bounceable: false,
                testnet: false
              )
        else {
            throw TONProviderError.accountDerivationUnavailable
        }
        return TONAccountMaterial(
            address: nonBounceable,
            rawAddress: raw,
            bounceableAddress: bounceable,
            publicKey: publicKey.data.base64EncodedString(),
            derivationPath: derivationPath
        )
    }

    static func rawAddress(from value: String) -> String? {
        let lowercased = value.lowercased()
        if lowercased.range(
            of: #"^(?:-1|0):[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil {
            return lowercased
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count.isMultiple(of: 4) == false {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              data.count == 36,
              CoinType.ton.validate(address: value),
              data[0] == 0x11 || data[0] == 0x51
        else {
            return nil
        }
        let workchain = Int8(bitPattern: data[1])
        let hash = data[2..<34].map {
            String(format: "%02x", $0)
        }.joined()
        return "\(workchain):\(hash)"
    }

    static func userFriendlyAddress(
        from value: String,
        bounceable: Bool
    ) -> String? {
        guard let raw = rawAddress(from: value) else { return nil }
        return TONAddressConverter.toUserFriendly(
            address: raw,
            bounceable: bounceable,
            testnet: false
        )
    }

    static func mainnetDisplayAddress(from value: String) -> String? {
        userFriendlyAddress(from: value, bounceable: false)
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = rawAddress(from: lhs),
              let right = rawAddress(from: rhs)
        else {
            return false
        }
        return left == right
    }
}
