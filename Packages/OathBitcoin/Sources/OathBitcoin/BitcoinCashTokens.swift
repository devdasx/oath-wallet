import Foundation

/// Decode only the CashTokens output prefix, leaving its locking script intact.
/// Raw bytes (including the prefix) stay committed by the funding txid. This
/// wallet counts the output's BCH, but does not offer token transfer/burning.
enum BitcoinCashTokens {
    static func lockingScript(_ prefixed: Data) throws -> Data {
        let bytes = Array(prefixed)
        guard bytes.first == 0xef else { return prefixed }
        guard bytes.count >= 34 else { throw BitcoinError.invalidResponse }
        let flags = bytes[33]
        let nft = flags & 0x20 != 0, amount = flags & 0x10 != 0, commitment = flags & 0x40 != 0
        guard flags & 0x80 == 0, flags & 0x0f <= 2, nft || flags & 0x0f == 0,
              nft || amount, !commitment || nft else { throw BitcoinError.invalidResponse }
        var offset = 34
        func compactSize() throws -> UInt64 {
            guard offset < bytes.count else { throw BitcoinError.invalidResponse }
            let first = bytes[offset]; offset += 1
            if first < 253 { return UInt64(first) }
            let length = first == 253 ? 2 : first == 254 ? 4 : 8
            guard length <= bytes.count - offset else { throw BitcoinError.invalidResponse }
            var value: UInt64 = 0
            for i in 0..<length { value |= UInt64(bytes[offset + i]) << (i * 8) }
            offset += length
            let minimum: UInt64 = length == 2 ? 253 : length == 4 ? 65_536 : 4_294_967_296
            guard value >= minimum else { throw BitcoinError.invalidResponse }
            return value
        }
        if commitment {
            let length = try compactSize()
            // Parse forward-compatible lengths, bounded by the transaction.
            // Consensus/proof validation is the node's job, not the wallet's.
            guard length > 0, length <= UInt64(bytes.count - offset) else { throw BitcoinError.invalidResponse }
            offset += Int(length)
        }
        if amount {
            let value = try compactSize()
            guard value > 0, value <= UInt64(Int64.max) else { throw BitcoinError.invalidResponse }
        }
        return Data(bytes.dropFirst(offset))
    }
}
