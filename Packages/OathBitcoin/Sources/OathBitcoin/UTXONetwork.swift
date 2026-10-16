import Foundation

/// Network rules for the shared public-descriptor discovery and ledger engine.
public enum UTXONetwork: String, Codable, Sendable, CaseIterable {
    case bitcoin, dogecoin, litecoin, bitcoincash
    public var maximumMoney: Int64 {
        switch self {
        case .bitcoin, .bitcoincash: 2_100_000_000_000_000
        case .dogecoin: Int64.max
        case .litecoin: 8_400_000_000_000_000
        }
    }
    // Core's ten-billion DOGE limit applies to a transaction/output, not to a
    // wallet balance. A wallet can own more, so aggregate using checked Int64.
    public var maximumOutput: Int64 {
        switch self {
        case .bitcoin, .litecoin, .bitcoincash: maximumMoney
        case .dogecoin: 1_000_000_000_000_000_000
        }
    }
    public var coinbaseMaturity: Int64 {
        switch self {
        case .bitcoin, .litecoin, .bitcoincash: 100
        case .dogecoin: 240
        }
    }

    /// Shared spending rule for every supported Bitcoin-family network. Normal
    /// outputs are eligible with zero confirmations, including incoming payments
    /// and change from an unconfirmed parent. Mining rewards still need maturity.
    /// The ledger must separately verify funding bytes, freshness, unspent state
    /// and reservations; eligibility does not guarantee eventual confirmation.
    public func permitsSpending(blockHeight: Int64?, tipHeight: Int64, isCoinbase: Bool, isPegout: Bool = false) -> Bool {
        guard tipHeight > 0 else { return false }
        let maturity = isCoinbase ? coinbaseMaturity : (self == .litecoin && isPegout ? 6 : 0)
        guard let height = blockHeight, height != 0 else { return maturity == 0 }
        guard height > 0, height <= tipHeight else { return false }
        return tipHeight - height + 1 >= maturity
    }
    public var genesis: String {
        switch self {
        case .bitcoin, .bitcoincash: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
        case .dogecoin: "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691"
        case .litecoin: "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2"
        }
    }
    // Genesis alone cannot distinguish BCH from BTC, BSV or eCash. This BCHN
    // checkpoint follows all of those splits. It identifies the peer's chain;
    // it is not SPV validation of every subsequently reported transaction.
    var checkpoint: (height: Int64, hash: String)? {
        self == .bitcoincash ? (792773, "000000000000000002fc0cdadaef1857bbd2936d37ea94f80ba3db4a5e8353e8") : nil
    }
    public var servers: [ElectrumServer] {
        switch self {
        case .bitcoin: ElectrumServer.publicMainnet
        case .bitcoincash: [ElectrumServer("electron.jochen-hoenicke.de", port: 51002),
                           ElectrumServer("bch.imaginary.cash"), ElectrumServer("bch0.kister.net")]
        case .dogecoin: [ElectrumServer("dogecoin.stackwallet.com", port: 50022),
                        ElectrumServer("electrum1.cipig.net", port: 20060),
                        ElectrumServer("electrum2.cipig.net", port: 20060)]
        case .litecoin: [ElectrumServer("electrum1.cipig.net", port: 20063),
                        ElectrumServer("electrum2.cipig.net", port: 20063)]
        }
    }

    public func wallet(seed: Data, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        switch self {
        case .bitcoin: try BitcoinKeys.wallet(seed: seed, account: account)
        case .dogecoin: try DogecoinKeys.wallet(seed: seed, account: account)
        case .litecoin: try LitecoinKeys.wallet(seed: seed, account: account)
        case .bitcoincash: try BitcoinCashKeys.wallet(seed: seed, account: account)
        }
    }
    public func extended(_ text: String) throws -> BitcoinWalletDescriptor {
        switch self {
        case .bitcoin: try BitcoinKeys.extended(text)
        case .dogecoin: try DogecoinKeys.extended(text)
        case .litecoin: try LitecoinKeys.extended(text)
        case .bitcoincash: try BitcoinCashKeys.extended(text)
        }
    }
    public func singleKey(bytes: Data, compressed: Bool) throws -> BitcoinWalletDescriptor {
        switch self {
        case .bitcoin: try BitcoinKeys.singleKey(bytes: bytes, compressed: compressed)
        case .dogecoin: try DogecoinKeys.singleKey(bytes: bytes, compressed: compressed)
        case .litecoin: try LitecoinKeys.singleKey(bytes: bytes, compressed: compressed)
        case .bitcoincash: try BitcoinCashKeys.singleKey(bytes: bytes, compressed: compressed)
        }
    }
    public func decodeImport(_ text: String) throws -> (bytes: Data, compressed: Bool, extended: String?) {
        switch self {
        case .bitcoin: try BitcoinKeys.decodeImport(text)
        case .dogecoin: try DogecoinKeys.decodeImport(text)
        case .litecoin: try LitecoinKeys.decodeImport(text)
        case .bitcoincash: try BitcoinCashKeys.decodeImport(text)
        }
    }
    public func wif(bytes: Data, compressed: Bool) throws -> String {
        switch self {
        case .bitcoin: try BitcoinKeys.wif(bytes: bytes, compressed: compressed)
        case .dogecoin: try DogecoinKeys.wif(bytes: bytes, compressed: compressed)
        case .litecoin: try LitecoinKeys.wif(bytes: bytes, compressed: compressed)
        case .bitcoincash: try BitcoinCashKeys.wif(bytes: bytes, compressed: compressed)
        }
    }
}
