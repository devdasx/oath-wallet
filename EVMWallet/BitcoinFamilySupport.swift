import Foundation
import WalletCore

/// Mainnet chain configuration shared by Bitcoin-family services.
enum BitcoinFamilyChain: String, CaseIterable, Sendable {
    case bitcoin
    case bitcoinCash = "bitcoin_cash"
    case litecoin
    case dogecoin

    var networkID: String { rawValue }

    var symbol: String {
        switch self {
        case .bitcoin: "BTC"
        case .bitcoinCash: "BCH"
        case .litecoin: "LTC"
        case .dogecoin: "DOGE"
        }
    }

    var nameKey: String { "network.\(rawValue).name" }
    var name: String { WalletLocalization.string(nameKey) }

    var transactionControlsTitle: String {
        EnglishNumbers.localized(
            "send.transaction_options.bitcoin.section",
            name
        )
    }

    var coin: CoinType {
        switch self {
        case .bitcoin: .bitcoin
        case .bitcoinCash: .bitcoinCash
        case .litecoin: .litecoin
        case .dogecoin: .dogecoin
        }
    }

    var derivationPath: String {
        switch self {
        case .bitcoin: "m/84'/0'/0'/0/0"
        case .bitcoinCash: "m/44'/145'/0'/0/0"
        case .litecoin: "m/84'/2'/0'/0/0"
        case .dogecoin: "m/44'/3'/0'/0/0"
        }
    }

    var blockchain: WalletBlockchain {
        switch self {
        case .bitcoin: .bitcoin
        case .bitcoinCash: .bitcoincash
        case .litecoin: .litecoin
        case .dogecoin: .dogecoin
        }
    }

    var databaseChainID: Int64 {
        switch self {
        case .bitcoin: -1
        case .bitcoinCash: -145
        case .litecoin: -2
        case .dogecoin: -3
        }
    }

    /// Whether the mainnet node policy implements BIP125 opt-in replacement.
    ///
    /// Bitcoin Cash removed BIP125 support, so transaction options must never
    /// expose or serialize an RBF preference for that chain.
    var supportsReplaceByFee: Bool {
        switch self {
        case .bitcoin, .litecoin, .dogecoin:
            true
        case .bitcoinCash:
            false
        }
    }

    /// Other Bitcoin-family chains have distinct relay policies, so the send
    /// flow exposes OP_RETURN only where its policy is explicitly supported.
    var supportsOPReturn: Bool {
        self == .bitcoin
    }

    var endpoints: [(String, UInt16)] {
        switch self {
        case .bitcoin:
            [("blockstream.info", 700),
             ("electrum.blockstream.info", 50002),
             ("bitcoin.stackwallet.com", 50002)]
        case .bitcoinCash:
            [("bch.loping.net", 50002),
             ("bch.imaginary.cash", 50002),
             ("bch.cyberbits.eu", 50002),
             ("electrum.imaginary.cash", 50002)]
        case .litecoin:
            [("electrum1.cipig.net", 20063),
             ("electrum2.cipig.net", 20063),
             ("litecoin.stackwallet.com", 20063)]
        case .dogecoin:
            [("electrum1.cipig.net", 20060),
             ("electrum2.cipig.net", 20060),
             ("dogecoin.stackwallet.com", 50022)]
        }
    }

    var genesisHash: String {
        switch self {
        case .bitcoin, .bitcoinCash:
            "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
        case .litecoin:
            "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2"
        case .dogecoin:
            "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691"
        }
    }
}

struct BitcoinFamilyAccountMaterial: Sendable {
    let chain: BitcoinFamilyChain
    let address: String
    let derivationPath: String?
    let publicKey: String
    let scriptPubKey: Data
}

struct BitcoinFamilyTransactionIdentity: Equatable, Sendable {
    let fromAddress: String?
    let toAddress: String?
}

enum BitcoinFamilyTransactionIdentityMapper {
    static func identity(
        chain: BitcoinFamilyChain,
        walletAddress: String,
        direction: String,
        inputAddresses: [String],
        outputAddresses: [String]
    ) -> BitcoinFamilyTransactionIdentity {
        let wallet = walletAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let inputs = validatedUniqueAddresses(
            inputAddresses,
            chain: chain
        )
        let outputs = validatedUniqueAddresses(
            outputAddresses,
            chain: chain
        )
        let isIncoming = ["in", "incoming", "received"].contains(
            direction.lowercased()
        )
        if isIncoming {
            return BitcoinFamilyTransactionIdentity(
                fromAddress: inputs.first { $0 != wallet }
                    ?? inputs.first,
                toAddress: outputs.first { $0 == wallet } ?? wallet
            )
        }
        return BitcoinFamilyTransactionIdentity(
            fromAddress: inputs.first { $0 == wallet } ?? wallet,
            toAddress: outputs.first { $0 != wallet }
                ?? outputs.first
        )
    }

    private static func validatedUniqueAddresses(
        _ addresses: [String],
        chain: BitcoinFamilyChain
    ) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap { value in
            let address = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !address.isEmpty,
                  chain.coin.validate(address: address),
                  seen.insert(address).inserted else {
                return nil
            }
            return address
        }
    }
}

struct BitcoinFamilyHistoryEntry: Sendable {
    let transactionHash: String
    let height: Int64
    let amountAtomic: BitcoinFamilyAtomicInteger
    let feeAtomic: BitcoinFamilyAtomicInteger?
    let direction: String
    let timestamp: Double?
    let identity: BitcoinFamilyTransactionIdentity?

    static func transferDirection(
        sent: BitcoinFamilyAtomicInteger,
        received: BitcoinFamilyAtomicInteger,
        totalInput: BitcoinFamilyAtomicInteger,
        totalOutput: BitcoinFamilyAtomicInteger,
        hasEveryInput: Bool
    ) -> String {
        // Moving between owned addresses still pays a miner fee, so a
        // negative net balance alone does not mean money went to someone else.
        if hasEveryInput, sent.isPositive, sent == totalInput, received == totalOutput {
            return "self"
        }
        return received.subtracting(sent).isPositive ? "incoming" : "outgoing"
    }

    init(
        transactionHash: String,
        height: Int64,
        amountAtomic: BitcoinFamilyAtomicInteger,
        feeAtomic: BitcoinFamilyAtomicInteger?,
        direction: String,
        timestamp: Double?,
        identity: BitcoinFamilyTransactionIdentity? = nil
    ) {
        self.transactionHash = transactionHash
        self.height = height
        self.amountAtomic = amountAtomic
        self.feeAtomic = feeAtomic
        self.direction = direction
        self.timestamp = timestamp
        self.identity = identity
    }
}

struct BitcoinFamilyChainSnapshot: Sendable {
    let material: BitcoinFamilyAccountMaterial
    let balanceAtomic: BitcoinFamilyAtomicInteger
    let history: [BitcoinFamilyHistoryEntry]
}
