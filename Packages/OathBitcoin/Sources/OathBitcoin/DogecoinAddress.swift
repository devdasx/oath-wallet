import Foundation

/// Dogecoin has no SegWit/Taproot destinations. P2SH is a recipient format;
/// imported/HD signing sources in this wallet are P2PKH only.
enum DogecoinAddress {
    static func encode(script: Data, network: BitcoinSendNetwork) throws -> String {
        guard [.mainnet, .testnet, .regtest].contains(network),
              BitcoinSendPlan.standardScript(script, chain: .dogecoin) else { throw BitcoinSendError.invalidRecipient }
        let main = network == .mainnet
        if script.count == 25 { return Base58Check.encode(Data([main ? 30 : network == .regtest ? 111 : 113]) + script.dropFirst(3).prefix(20)) }
        return Base58Check.encode(Data([main ? 22 : 196]) + script.dropFirst(2).prefix(20))
    }
    static func decode(_ value: String, network: BitcoinSendNetwork) throws -> Data {
        guard [.mainnet, .testnet, .regtest].contains(network), value.utf8.count <= 35,
              let payload = try? Base58Check.decode(value), payload.count == 21 else { throw BitcoinSendError.invalidRecipient }
        if payload.first == (network == .mainnet ? 30 : network == .regtest ? 111 : 113) {
            return Data([0x76,0xa9,20]) + payload.dropFirst() + Data([0x88,0xac])
        }
        if payload.first == (network == .mainnet ? 22 : 196) {
            return Data([0xa9,20]) + payload.dropFirst() + Data([0x87])
        }
        throw BitcoinSendError.invalidRecipient
    }
}

extension UTXONetwork {
    // Dogecoin Core recommends 0.01 DOGE/kB, above its relay-only floor.
    var sendFeeRates: ClosedRange<Int64> { self == .dogecoin ? 1_000_000...100_000_000 : 1_000...1_000_000 }
    var maximumSendFee: Int64 { self == .dogecoin ? 10_000_000_000 : 10_000_000 }
}
