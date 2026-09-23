import Foundation
import WalletCore

extension DeviceMigrationAccountSecretVerifier {
    static func bitcoinFamilyAddressCandidates(
        publicKey: PublicKey,
        chain: BitcoinFamilyChain
    ) -> Set<String> {
        var candidates: Set<String> = [
            chain.coin.deriveAddressFromPublicKey(publicKey: publicKey)
        ]
        guard publicKey.isCompressed else { return candidates }
        switch chain {
        case .bitcoin:
            candidates.insert(
                SegwitAddress(
                    hrp: .bitcoin,
                    publicKey: publicKey
                ).description
            )
            candidates.insert(
                nestedSegwitAddress(
                    publicKey: publicKey,
                    scriptHashPrefix: 0x05
                )
            )
        case .litecoin:
            candidates.insert(
                SegwitAddress(
                    hrp: .litecoin,
                    publicKey: publicKey
                ).description
            )
            candidates.insert(
                nestedSegwitAddress(
                    publicKey: publicKey,
                    scriptHashPrefix: 0x32
                )
            )
        case .bitcoinCash, .dogecoin:
            break
        }
        return candidates
    }

    static func nestedSegwitAddress(
        publicKey: PublicKey,
        scriptHashPrefix: UInt8
    ) -> String {
        let redeemScript = BitcoinScript
            .buildPayToWitnessPubkeyHash(
                hash: publicKey.bitcoinKeyHash
            )
        var payload = Data([scriptHashPrefix])
        payload.append(redeemScript.scriptHash)
        return Base58.encode(data: payload)
    }

    static func accountFamily(
        networkID: String
    ) throws -> AccountFamily {
        if BitcoinFamilyChain(rawValue: networkID) != nil {
            return .bitcoinFamily
        }
        if networkID == TronConstants.networkID {
            return .tron
        }
        if networkID == SolanaConstants.networkID {
            return .solana
        }
        if networkID == TONConstants.networkID {
            return .ton
        }
        if networkID == SuiConstants.networkID {
            return .sui
        }
        if networkID == XRPConstants.networkID {
            return .xrp
        }
        if networkID == NEARConstants.networkID {
            return .near
        }
        if networkID == AptosConstants.networkID {
            return .aptos
        }
        if networkID == StellarConstants.networkID {
            return .stellar
        }
        guard
            let network = ReceiveNetworkCatalog.network(for: networkID),
            network.chainID > 0
        else {
            throw VerificationFailure(
                reason: .unsupportedNetwork,
                family: .unknown
            )
        }
        return .evm
    }

    static func accountFamily(
        for network: PrivateKeyImportNetwork
    ) -> AccountFamily {
        switch network {
        case .evm: .evm
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            .bitcoinFamily
        case .tron: .tron
        case .solana: .solana
        case .ton: .ton
        case .sui: .sui
        case .xrp: .xrp
        case .near: .near
        case .aptos: .aptos
        case .stellar: .stellar
        }
    }

    static func isValidAddress(
        _ address: String,
        family: AccountFamily,
        networkID: String
    ) -> Bool {
        switch family {
        case .evm:
            CoinType.ethereum.validate(address: address)
        case .bitcoinFamily:
            BitcoinFamilyChain(rawValue: networkID)?
                .coin.validate(address: address) ?? false
        case .tron:
            CoinType.tron.validate(address: address)
        case .solana:
            CoinType.solana.validate(address: address)
        case .ton:
            TONAddress.rawAddress(from: address) != nil
        case .sui:
            SuiCoinType.canonicalAccountAddress(address) != nil
        case .xrp:
            CoinType.xrp.validate(address: address)
        case .near:
            NEARAddress.isValid(address)
        case .aptos:
            AptosAddress.canonical(address) != nil
        case .stellar:
            StellarAddress.isValid(address)
        case .unknown:
            false
        }
    }

    static func decodedPublicKey(
        _ encoded: String,
        family: AccountFamily
    ) -> Data? {
        switch family {
        case .evm, .bitcoinFamily, .xrp:
            return Data(hexString: encoded)
        case .tron:
            if [66, 130].contains(encoded.utf8.count),
               let hexadecimal = Data(hexString: encoded) {
                return hexadecimal
            }
            return Data(base64Encoded: encoded)
        case .aptos, .solana, .ton, .sui, .stellar:
            if encoded.utf8.count == 64,
               let hexadecimal = Data(hexString: encoded) {
                return hexadecimal
            }
            return Data(base64Encoded: encoded)
        case .near:
            guard encoded.hasPrefix("ed25519:") else { return nil }
            return Base58.decodeNoCheck(
                string: String(encoded.dropFirst("ed25519:".count))
            )
        case .unknown:
            return nil
        }
    }
}
