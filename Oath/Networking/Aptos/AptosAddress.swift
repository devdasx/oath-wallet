import Foundation
import WalletCore

enum AptosAddress {
    private static let zero = "0x" + String(repeating: "0", count: 64)

    static func canonical(_ value: String) -> String? {
        var hexadecimal = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if hexadecimal.hasPrefix("0x") { hexadecimal.removeFirst(2) }
        guard (1...64).contains(hexadecimal.count),
              hexadecimal.allSatisfy(\.isHexDigit)
        else { return nil }
        let address = "0x"
            + String(repeating: "0", count: 64 - hexadecimal.count)
            + hexadecimal
        guard address != zero, CoinType.aptos.validate(address: address) else {
            return nil
        }
        return address
    }

    static func material(
        privateKey: PrivateKey,
        derivationPath: String?
    ) throws -> AptosAccountMaterial {
        let address = CoinType.aptos.deriveAddress(privateKey: privateKey)
        guard let canonical = canonical(address) else {
            throw AptosProviderError.invalidAddress
        }
        return AptosAccountMaterial(
            address: canonical,
            publicKey: privateKey.getPublicKeyEd25519().data
                .map { String(format: "%02x", $0) }
                .joined(),
            derivationPath: derivationPath
        )
    }

    static func validatedPersistedMaterial(
        address: String,
        normalizedAddress: String,
        publicKey: String?,
        derivationPath: String?
    ) -> AptosAccountMaterial? {
        guard
            let canonicalAddress = canonical(address),
            normalizedAddress == canonicalAddress,
            address == canonicalAddress,
            let publicKey,
            publicKey == publicKey.lowercased(),
            publicKey.utf8.count == 64,
            let publicKeyData = Data(hexString: publicKey),
            publicKeyData.count == 32,
            let parsedPublicKey = PublicKey(
                data: publicKeyData,
                type: .ed25519
            ),
            canonical(
                CoinType.aptos.deriveAddressFromPublicKey(
                    publicKey: parsedPublicKey
                )
            ) == canonicalAddress
        else {
            return nil
        }
        return AptosAccountMaterial(
            address: canonicalAddress,
            publicKey: publicKey,
            derivationPath: derivationPath
        )
    }

    /// Derives the canonical Aptos identity exclusively through Trust Wallet
    /// Core and verifies its coin-level address API against the private-key
    /// derivation before the identity is persisted.
    static func material(hdWallet: HDWallet) throws -> AptosAccountMaterial {
        let privateKey = hdWallet.getKeyForCoin(coin: .aptos)
        let material = try material(
            privateKey: privateKey,
            derivationPath: AptosConstants.derivationPath
        )
        guard let walletCoreAddress = canonical(
            hdWallet.getAddressForCoin(coin: .aptos)
        ), walletCoreAddress == material.address else {
            throw AptosProviderError.invalidAddress
        }
        return material
    }
}
