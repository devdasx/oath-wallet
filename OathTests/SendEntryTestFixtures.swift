import Foundation
import Testing
@testable import Aperture

enum SendEntryTestFixtures {
    static let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
    static let ethereum = NativeListTestFixtures.sendChoices[0]

    static func zeroBalanceChoice(isToken: Bool) -> SendAssetChoice {
        SendAssetChoice(
            id: isToken ? "eth:0x1111111111111111111111111111111111111111" : "bitcoin:native",
            name: isToken ? "Token" : "Bitcoin", symbol: isToken ? "TOKEN" : "BTC",
            networkID: isToken ? "eth" : "bitcoin",
            networkName: isToken ? "Ethereum" : "Bitcoin",
            blockchain: isToken ? .ethereum : .bitcoin,
            contractAddress: isToken ? "0x1111111111111111111111111111111111111111" : nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .network(blockchain: isToken ? .ethereum : .bitcoin),
            balance: 0, fiatValue: 0, balanceAtomic: "0"
        )
    }

    static func draft(
        asset: SendAssetChoice = ethereum,
        recipient: String? = nil,
        amount: String? = nil,
        memo: String? = nil
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: asset.networkID).replacingMemo(memo),
            asset: asset,
            recipient: recipient ?? address(for: asset.blockchain),
            amount: amount,
            note: nil
        )
    }

    static func nativeChoice(for network: AssetNetworkSelectorOption) throws -> SendAssetChoice {
        // Ordinary entry tests need a recipient distinct from the sender
        // on protocols that reject direct self-payments.
        let sourceAddress = switch network.blockchain {
        case .tron: "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
        case .xrp: "rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY"
        default: address(for: network.blockchain)
        }
        let asset = WalletAsset(
            id: AssetIdentityKey.make(networkID: network.id, contractAddress: nil),
            name: network.localizedName,
            symbol: network.blockchain.rawValue.uppercased(),
            logoSource: .nativeCoin(blockchain: network.blockchain),
            network: network.blockchain,
            balance: 100,
            fiatValue: 200,
            receiveAddress: sourceAddress
        )
        return try #require(SendAssetChoiceCatalog.choices(
            from: [asset], capabilities: .fullWallet
        ).first)
    }

    static func address(for blockchain: WalletBlockchain) -> String {
        switch blockchain {
        case .bitcoin: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        case .bitcoincash: "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        case .litecoin: "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
        case .dogecoin: "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
        case .solana: "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
        case .tron: "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"
        case .ton: "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
        case .sui: "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"
        case .aptos: "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
        case .near: "alice.near"
        case .xrp: "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
        case .stellar: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        default: NativeListTestFixtures.address
        }
    }
}
