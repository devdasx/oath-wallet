import Foundation
import WalletCore

enum ReceiveAddressResolutionError: Error {
    case noSelectedWallet

    var diagnosticDescription: String {
        switch self {
        case .noSelectedWallet:
            "no_selected_wallet"
        }
    }
}

enum ReceiveAddressResolver {
    static func requiresIndependentAddress(
        for blockchain: WalletBlockchain?
    ) -> Bool {
        guard let blockchain else { return false }
        if BitcoinFamilyChain.allCases.contains(where: {
            $0.blockchain == blockchain
        }) {
            return true
        }

        switch blockchain {
        case .aptos, .near, .stellar, .xrp, .sui, .ton, .tron, .solana:
            return true
        case .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll,
             .linea, .taiko, .telos, .xlayer, .arc,
             .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            return false
        }
    }

    static func paymentPayload(
        address: String,
        network: ReceiveNetwork,
        contractAddress: String?
    ) -> String {
        if let scheme = explicitIndependentScheme(
            for: network.blockchain
        ) {
            var payload = "\(scheme):\(address)"
            if let contractAddress,
               !contractAddress.isEmpty,
               let encodedAsset = queryValue(contractAddress) {
                payload += "?asset=\(encodedAsset)"
            }
            return payload
        }
        if requiresIndependentAddress(for: network.blockchain) {
            return address
        }
        if let contractAddress {
            return "ethereum:\(contractAddress)@\(network.chainID)"
                + "/transfer?address=\(address)"
        }
        return "ethereum:\(address)@\(network.chainID)"
    }

    private static func explicitIndependentScheme(
        for blockchain: WalletBlockchain?
    ) -> String? {
        switch blockchain {
        case .aptos: "aptos"
        case .near: "near"
        case .sui: "sui"
        default: nil
        }
    }

    private static func queryValue(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func independentAddress(
        for blockchain: WalletBlockchain,
        database: WalletDatabase
    ) async throws -> String? {
        guard let identity = try await database.selectedWalletIdentity()
        else {
            throw ReceiveAddressResolutionError.noSelectedWallet
        }
        return try await database.accountAddressIndex(
            walletID: identity.walletID
        )
        .address(for: blockchain)
    }

    static func validatedIndependentAddress(
        _ address: String?,
        for blockchain: WalletBlockchain?
    ) -> String? {
        guard
            let blockchain,
            let address,
            !address.isEmpty
        else {
            return nil
        }

        if blockchain == .tron {
            return AnyAddress(string: address, coin: .tron) == nil
                ? nil : address
        }
        if blockchain == .solana {
            return AnyAddress(string: address, coin: .solana) == nil
                ? nil : address
        }
        if blockchain == .ton {
            return TONAddress.rawAddress(from: address) == nil
                ? nil : address
        }
        if blockchain == .sui {
            return SuiCoinType.validatedAccountAddress(address)
        }
        if blockchain == .xrp {
            return AnyAddress(string: address, coin: .xrp) == nil
                ? nil : address
        }
        if blockchain == .near {
            return NEARAddress.isValid(address) ? address : nil
        }
        if blockchain == .aptos {
            return AptosAddress.canonical(address)
        }
        if blockchain == .stellar {
            return StellarAddress.isValid(address) ? address : nil
        }
        guard let chain = BitcoinFamilyChain.allCases.first(where: {
            $0.blockchain == blockchain
        }) else {
            return nil
        }
        return AnyAddress(string: address, coin: chain.coin) == nil
            ? nil : address
    }
}
