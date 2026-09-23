import Foundation
import WalletCore

enum StellarAddress {
    static func isValid(_ candidate: String) -> Bool {
        validated(candidate) != nil
    }

    static func validated(_ candidate: String) -> String? {
        let normalized = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized == normalized.uppercased(),
              normalized.utf8.count == 56,
              CoinType.stellar.validate(address: normalized),
              AnyAddress(string: normalized, coin: .stellar) != nil
        else { return nil }
        return normalized
    }

    static func material(
        privateKey: PrivateKey,
        derivationPath: String?
    ) throws -> StellarAccountMaterial {
        let address = CoinType.stellar.deriveAddress(privateKey: privateKey)
        guard let address = validated(address) else {
            throw StellarProviderError.invalidAddress
        }
        return StellarAccountMaterial(
            address: address,
            publicKey: privateKey.getPublicKeyEd25519().description,
            derivationPath: derivationPath
        )
    }
}
