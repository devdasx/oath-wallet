import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinSendOptionsTests: XCTestCase {
    private let btc = BitcoinSendTests()
    private let doge = DogecoinSendTests()
    private let bch = BitcoinCashSendTests()
    private let ltc = LitecoinSendTests()

    func testByteLimitsAndPushdataBoundaries() throws {
        for chain in UTXONetwork.allCases {
            let maximum = BitcoinSendOptions.maximumMessageBytes(chain)
            let options = BitcoinSendOptions(message: Data(repeating: 0x61, count: maximum))
            try options.validate(chain: chain)
            XCTAssertEqual(options.dataScript!.count, chain == .bitcoin ? 100_000 : chain == .bitcoincash ? 223 : 83)
            XCTAssertThrowsError(try BitcoinSendOptions(message: Data(repeating: 0x61, count: maximum + 1)).validate(chain: chain))
            XCTAssertNil(BitcoinSendOptions().dataScript)
            XCTAssertFalse(BitcoinSendOptions().replaceable)
        }
        for (size, prefix) in [(1,[0x6a,1]), (75,[0x6a,75]), (76,[0x6a,0x4c,76]), (255,[0x6a,0x4c,255]),
                               (256,[0x6a,0x4d,0,1]), (65535,[0x6a,0x4d,255,255]), (65536,[0x6a,0x4e,0,0,1,0])] {
            let data = Data(repeating: 0x61, count: size)
            XCTAssertEqual(BitcoinSendOptions(message: data).dataScript, Data(prefix.map(UInt8.init)) + data)
        }
        let unicode = String(repeating: "💙", count: 20)
        XCTAssertEqual(unicode.utf8.count, 80)
        try BitcoinSendOptions(message: Data(unicode.utf8)).validate(chain: .dogecoin)
        XCTAssertThrowsError(try BitcoinSendOptions(message: Data((unicode + "a").utf8)).validate(chain: .dogecoin))
        for chain in [UTXONetwork.litecoin, .bitcoincash] {
            XCTAssertThrowsError(try BitcoinSendOptions(replaceable: true).validate(chain: chain))
        }
    }

    func testBitcoinRBFAndMessageForEveryAddressTypeAndBothBranches() throws {
        for type in BitcoinAddressType.allCases {
            for branch: UInt32 in [0,1] {
                for rbf in [false,true] {
                    for size in [0,80,256,1024] {
                        let options = BitcoinSendOptions(replaceable: rbf, message: Data(repeating: 0x61, count: size))
                        let p = try BitcoinSendPlan.make(coins: [btc.coin(2_000_000, type: type, change: branch)], recipient: btc.address(type, index: 500).address,
                            amount: 1_000_000, change: btc.address(type, change: 1, index: 20), ratePerKVByte: 2000, options: options)
                        XCTAssertEqual(p.inputSequence, rbf ? 0xfffffffd : 0xfffffffe)
                        try check(p, source: { _ in .seed(self.btc.seed, account: 0) })
                    }
                }
            }
        }
    }

    func testDogecoinRBFWithCompressedUncompressedAndHDChange() throws {
        for compression: Bool? in [nil,true,false] {
            for branch: UInt32 in [0,1] {
                for rbf in [false,true] {
                    let p = try BitcoinSendPlan.make(coins: [doge.coin(100_000_000, change: branch, imported: compression)],
                        recipient: doge.address(index: 500).address, amount: 50_000_000, change: doge.address(change: 1),
                        ratePerKVByte: 1_000_000, chain: .dogecoin, options: .init(replaceable: rbf, message: Data("Oath 💙".utf8)))
                    XCTAssertEqual(p.inputSequence, rbf ? 0xfffffffd : 0xfffffffe)
                    // Zero-value unspendable data must not incur DOGE soft-dust surcharge.
                    XCTAssertEqual(p.fee, BitcoinSendPlan.feeFor(p.maximumVBytes, p.ratePerKVByte))
                    try check(p, source: { _ in compression.map { .single(self.doge.single, compressed: $0) } ?? .seed(self.doge.seed, account: 0) })
                }
            }
        }
    }

    func testAllChainsDataFeeSweepAndMaximumMessages() throws {
        for chain in UTXONetwork.allCases {
            let coin: BitcoinSendCoin
            let destination: BitcoinDerivedAddress
            let change: BitcoinDerivedAddress
            switch chain {
            case .bitcoin: coin = try btc.coin(2_000_000); destination = try btc.address(index: 50); change = try btc.address(change: 1)
            case .dogecoin: coin = try doge.coin(100_000_000); destination = try doge.address(index: 50); change = try doge.address(change: 1)
            case .bitcoincash: coin = try bch.funding(bch.address(), value: 2_000_000); destination = try bch.address(index: 50); change = try bch.address(change: 1)
            case .litecoin: coin = try ltc.coin(2_000_000); destination = try ltc.address(index: 50); change = try ltc.address(change: 1)
            }
            let rate: Int64 = chain == .dogecoin ? 1_000_000 : 1000
            for amount in [coin.value / 2, coin.value] {
                let plain = try BitcoinSendPlan.make(coins: [coin], recipient: destination.address, amount: amount, change: change, ratePerKVByte: rate, chain: chain)
                let size = chain == .bitcoin ? 98_000 : BitcoinSendOptions.maximumMessageBytes(chain)
                let p = try BitcoinSendPlan.make(coins: [coin], recipient: destination.address, amount: amount, change: change, ratePerKVByte: rate, chain: chain,
                    options: .init(message: Data(repeating: 0x61, count: size)))
                XCTAssertGreaterThan(p.fee, plain.fee)
                XCTAssertEqual(p.outputs.last?.value, 0)
                XCTAssertEqual(p.outputs.count, p.changeAmount > 0 ? 3 : 2)
                XCTAssertEqual(p.total + p.remainingBalance, coin.value)
                XCTAssertEqual(p.changeAmount == 0, amount == coin.value)
                try check(p, source: { _ in .seed(Data(0..<32), account: 0) })
            }
        }
    }

    func testMixedInputsAndScriptHashRecipientsWithMessages() throws {
        for chain in UTXONetwork.allCases {
            let coins: [BitcoinSendCoin]
            let change: BitcoinDerivedAddress
            let destinations: [String]
            switch chain {
            case .bitcoin, .litecoin:
                coins = try BitcoinAddressType.allCases.enumerated().map { i, type in
                    try chain == .bitcoin ? btc.coin(100_000, type: type, index: UInt32(i), change: UInt32(i % 2))
                        : ltc.coin(100_000, type: type, index: UInt32(i), change: UInt32(i % 2))
                }
                change = try chain == .bitcoin ? btc.address(change: 1) : ltc.address(change: 1)
                destinations = try BitcoinAddressType.allCases.map { type in
                    try chain == .bitcoin ? btc.address(type, index: 90).address : ltc.address(type, index: 90).address
                }
            case .dogecoin:
                coins = try [doge.coin(100_000_000), doge.coin(100_000_000, index: 1, change: 1)]
                change = try doge.address(change: 1)
                destinations = [try DogecoinAddress.encode(script: Data([0xa9,20]) + Data(repeating: 7, count: 20) + Data([0x87]), network: .mainnet)]
            case .bitcoincash:
                coins = try [bch.funding(bch.address(), value: 100_000), bch.funding(bch.address(change: 1), value: 100_000, nonce: 1)]
                change = try bch.address(change: 1)
                destinations = try [Data([0xa9,20]) + Data(repeating: 7, count: 20) + Data([0x87]),
                                    Data([0xaa,32]) + Data(repeating: 8, count: 32) + Data([0x87])].map { try CashAddress.encode(script: $0, prefix: "bitcoincash") }
            }
            for destination in destinations {
                let p = try BitcoinSendPlan.make(coins: coins, recipient: destination, amount: coins.reduce(0) { $0 + $1.value },
                    change: change, ratePerKVByte: chain == .dogecoin ? 1_000_000 : 2000, chain: chain,
                    options: .init(replaceable: BitcoinSendOptions.supportsRBF(chain), message: Data("Mixed input message".utf8)))
                XCTAssertEqual(p.coins.count, coins.count)
                try check(p, source: { _ in .seed(Data(0..<32), account: 0) })
            }
        }
    }

    func testWholeTransactionLimitAndOldJournalCompatibility() throws {
        let p = try btc.plan([btc.coin(2_000_000)], amount: 1_000_000)
        XCTAssertThrowsError(try BitcoinSendPlan.make(coins: p.coins, recipient: p.recipient, amount: p.requestedAmount, change: p.change,
            ratePerKVByte: p.ratePerKVByte, options: .init(message: Data(repeating: 97, count: 99_994)))) {
            XCTAssertEqual($0 as? BitcoinSendError, .tooLarge)
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "optionsValue")
        let old = try JSONDecoder().decode(BitcoinSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.inputSequence, 0xfffffffd)
        XCTAssertTrue(old.options.message.isEmpty)
        try check(old, source: { _ in .seed(self.btc.seed, account: 0) })
    }

    func testSignedMessageAndSequenceCannotDifferFromReview() throws {
        let p = try BitcoinSendPlan.make(coins: [btc.coin(1_000_000)], recipient: btc.address(index: 50).address, amount: 500_000,
            change: btc.address(change: 1), ratePerKVByte: 1000, options: .init(replaceable: true, message: Data("Original message".utf8)))
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.btc.seed, account: 0) }
        for replacement in [BitcoinSendOptions(replaceable: false, message: p.options.message),
                            .init(replaceable: true, message: Data("Modified message".utf8))] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
            json["optionsValue"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacement))
            let changed = try JSONDecoder().decode(BitcoinSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try changed.validateSigned(signed))
        }
    }

    private func check(_ plan: BitcoinSendPlan, source: (String) throws -> BitcoinPrivateKeySource) throws {
        try plan.validate()
        XCTAssertEqual(try JSONDecoder().decode(BitcoinSendPlan.self, from: JSONEncoder().encode(plan)), plan)
        let signed = try plan.chain == .bitcoincash ? BitcoinCashSendSigner.sign(plan, source: source) : BitcoinSendSigner.sign(plan, source: source)
        try plan.validateSigned(signed)
        let tx = try BitcoinTransactions.details(signed.raw, network: plan.chain)
        XCTAssertEqual(tx.outputs.count, plan.outputs.count)
        for (actual, expected) in zip(tx.outputs, plan.outputs) {
            XCTAssertEqual(actual.value, expected.value)
            XCTAssertEqual(actual.script, expected.script.hex)
        }
    }
}
