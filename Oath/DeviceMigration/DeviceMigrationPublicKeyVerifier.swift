import Foundation
import WalletCore

extension DeviceMigrationAccountSecretVerifier {
    static func isCurveValid(
        _ publicKey: PublicKey,
        family: AccountFamily
    ) -> Bool {
        // WalletCore's PublicKey initializer validates only encoding shape.
        // These derivation entry points parse the point with the curve-aware
        // key implementation before deriving an address.
        switch family {
        case .solana:
            let address = CoinType.solana.deriveAddressFromPublicKey(
                publicKey: publicKey
            )
            return CoinType.solana.validate(address: address)
        case .ton:
            let address = AnyAddress(
                publicKey: publicKey,
                coin: .ton
            ).description
            return CoinType.ton.validate(address: address)
        case .sui:
            let address = CoinType.sui.deriveAddressFromPublicKey(
                publicKey: publicKey
            )
            return CoinType.sui.validate(address: address)
        case .near:
            return publicKey.data.count == 32
        case .aptos:
            let address = CoinType.aptos.deriveAddressFromPublicKey(
                publicKey: publicKey
            )
            return AptosAddress.canonical(address) != nil
        case .stellar:
            let address = CoinType.stellar.deriveAddressFromPublicKey(
                publicKey: publicKey
            )
            return StellarAddress.isValid(address)
        case .evm, .tron, .bitcoinFamily, .xrp:
            let address = CoinType.ethereum.deriveAddressFromPublicKey(
                publicKey: publicKey
            )
            return CoinType.ethereum.validate(address: address)
        case .unknown:
            return false
        }
    }

    static func hardwarePublicKey(
        _ publicKey: PublicKey,
        matches account: DBWalletAccountRecord,
        family: AccountFamily
    ) -> Bool {
        switch family {
        case .evm:
            return CoinType.ethereum.deriveAddressFromPublicKey(
                publicKey: publicKey
            ).caseInsensitiveCompare(account.address) == .orderedSame
        case .tron:
            return CoinType.tron.deriveAddressFromPublicKey(
                publicKey: publicKey
            ) == account.address
        case .solana:
            return CoinType.solana.deriveAddressFromPublicKey(
                publicKey: publicKey
            ) == account.address
        case .ton:
            let derived = AnyAddress(
                publicKey: publicKey,
                coin: .ton
            ).description
            return TONAddress.rawAddress(from: derived)
                == TONAddress.rawAddress(from: account.address)
        case .sui:
            return SuiCoinType.canonicalAccountAddress(
                CoinType.sui.deriveAddressFromPublicKey(
                    publicKey: publicKey
                )
            ) == SuiCoinType.canonicalAccountAddress(account.address)
        case .near:
            return NEARAddress.implicitAddress(publicKey: publicKey)
                == account.address
        case .aptos:
            return AptosAddress.canonical(
                CoinType.aptos.deriveAddressFromPublicKey(
                    publicKey: publicKey
                )
            ) == AptosAddress.canonical(account.address)
        case .stellar:
            return StellarAddress.validated(
                CoinType.stellar.deriveAddressFromPublicKey(
                    publicKey: publicKey
                )
            ) == StellarAddress.validated(account.address)
        case .xrp:
            return CoinType.xrp.deriveAddressFromPublicKey(
                publicKey: publicKey
            ) == account.address
        case .bitcoinFamily:
            guard let chain = BitcoinFamilyChain(
                rawValue: account.networkID
            ) else {
                return false
            }
            return bitcoinFamilyAddressCandidates(
                publicKey: publicKey,
                chain: chain
            ).contains(account.address)
        case .unknown:
            return false
        }
    }
}
