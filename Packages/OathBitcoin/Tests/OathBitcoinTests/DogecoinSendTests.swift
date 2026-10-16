import Foundation
import XCTest
@testable import OathBitcoin

final class DogecoinSendTests: XCTestCase {
    // Public deterministic fixtures; never funded on mainnet.
    let seed = Data(0..<32)
    let single = Data(repeating: 0, count: 31) + Data([1])
    func address(change: UInt32 = 0, index: UInt32 = 0) throws -> BitcoinDerivedAddress {
        let branch = try DogecoinKeys.wallet(seed: seed).branches.first { $0.change == change }!
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
    }
    func imported(_ compressed: Bool) throws -> BitcoinDerivedAddress {
        try BitcoinKeys.addresses(branch: DogecoinKeys.singleKey(bytes: single, compressed: compressed).branches[0], range: 0..<1)[0]
    }
    func coin(_ value: Int64, index: UInt32 = 0, change: UInt32 = 0, imported compression: Bool? = nil,
              derived: BitcoinDerivedAddress? = nil) throws -> BitcoinSendCoin {
        let a = try derived ?? compression.map { try imported($0) } ?? address(change: change, index: index)
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(index) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(value)) + BitcoinWire.vector(Data(hex: a.script)!) + BitcoinWire.little(UInt32(0))
        return .init(accountID: compression == nil ? "hd" : compression! ? "compressed" : "uncompressed", txid: try BitcoinTransactions.txid(raw, network: .dogecoin),
                     vout: 0, value: value, address: a, previousTransaction: raw, compressed: compression ?? true)
    }
    func plan(_ coins: [BitcoinSendCoin], amount: Int64, rate: Int64 = 1_000_000) throws -> BitcoinSendPlan {
        try .make(coins: coins, recipient: address(index: 900).address, amount: amount,
                  change: address(change: 1), ratePerKVByte: rate, chain: .dogecoin)
    }
    func testNetworkPrefixesChecksumsAndWitnessRejection() throws {
        let a = try address(), script = Data(hex: a.script)!
        for (network, prefix) in [(BitcoinSendNetwork.mainnet,UInt8(30)),(.testnet,113),(.regtest,111)] {
            let value = try BitcoinSendPlan.address(a,on:network,chain:.dogecoin)
            XCTAssertEqual(try Base58Check.decode(value).first,prefix)
            XCTAssertEqual(try BitcoinSendPlan.recipientScript(value,chain:.dogecoin,network:network),script)
            XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(value+"q",chain:.dogecoin,network:network))
            for other in [BitcoinSendNetwork.mainnet,.testnet,.regtest] where other != network {
                XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(value,chain:.dogecoin,network:other))
            }
            let sh = Data([0xa9,20])+Data(repeating:7,count:20)+Data([0x87])
            XCTAssertEqual(try DogecoinAddress.decode(DogecoinAddress.encode(script:sh,network:network),network:network),sh)
        }
        XCTAssertThrowsError(try BitcoinSendPlan.address(a,on:.chipnet,chain:.dogecoin))
        XCTAssertThrowsError(try BitcoinSendPlan.address(a,on:.testnet4,chain:.dogecoin))
        for script in [Data([0,20])+Data(repeating:1,count:20),Data([0x51,32])+Data(repeating:1,count:32)] {
            XCTAssertFalse(BitcoinSendPlan.standardScript(script,chain:.dogecoin))
            XCTAssertThrowsError(try DogecoinAddress.encode(script:script,network:.mainnet))
        }
    }
    func testFeeUsesRemainderThenAdjustedAmountAndKeepsTinyUnspentBalance() throws {
        let c = try coin(100_000_000)
        let normal = try plan([c],amount:50_000_000)
        XCTAssertEqual(normal.recipientAmount,50_000_000); XCTAssertEqual(normal.deductedFromAmount,0)
        XCTAssertEqual(normal.changeAmount,50_000_000-normal.fee)
        for amount: Int64 in [100_000_000,99_999_999] {
            let p = try plan([c],amount:amount)
            XCTAssertEqual(p.recipientAmount,c.value-p.fee); XCTAssertEqual(p.changeAmount,0)
            XCTAssertEqual(p.deductedFromAmount,amount-p.recipientAmount); try p.validate()
        }
        let smallRemainder = try plan([c,coin(10_000,index:1)],amount:99_700_000)
        XCTAssertEqual(smallRemainder.coins.count,1); XCTAssertEqual(smallRemainder.remainingBalance,10_000)
        XCTAssertEqual(smallRemainder.recipientAmount,99_700_000)
        XCTAssertEqual(smallRemainder.changeAmount,0)
    }
    func testHardDustSoftDustFeesAndBoundaryAfterDeduction() throws {
        XCTAssertEqual(BitcoinSendPlan.dust(Data(hex:try address().script)!,chain:.dogecoin),100_000)
        XCTAssertThrowsError(try plan([coin(100_000_000)],amount:99_999))
        for amount: Int64 in [100_000,999_999,1_000_000,1_000_001] {
            let p = try plan([coin(100_000_000)],amount:amount)
            XCTAssertEqual(p.fee,BitcoinSendPlan.feeFor(p.maximumVBytes,p.ratePerKVByte)+(amount<1_000_000 ? 1_000_000:0))
            try p.validate(); _ = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
        }
        // Deduction can cross the soft-dust boundary and must price it again.
        XCTAssertThrowsError(try plan([coin(1_500_000)],amount:1_500_000,rate:3_000_000))
    }
    func testManyInputsMixedReceiveChangeAndCompressionSign() throws {
        let coins = try (0..<253).map { try coin(2_000_000,index:UInt32($0),change:UInt32($0%2)) }
            + [coin(2_000_000,index:500,imported:true),coin(2_000_000,index:501,imported:false)]
        let p = try plan(coins,amount:510_000_000)
        XCTAssertEqual(p.coins.count,255)
        let signed = try BitcoinSendSigner.sign(p) { id in
            if id != "hd" { return .single(self.single,compressed:id == "compressed") }; return .seed(self.seed,account:0)
        }
        XCTAssertEqual(try BitcoinTransactions.txid(signed.raw,network:.dogecoin),signed.txid)
        XCTAssertLessThanOrEqual(signed.virtualBytes,UInt64(p.maximumVBytes))
    }
    func testObservedHighDogecoinRatesSignWithoutBitcoinsFeeCeiling() throws {
        // These are the live 2026-10-13 atomic/kB quotes behind the reported
        // ~51k atomic/vB extraction error, plus both allowed boundary rates.
        for rate: Int64 in [1_000_000, 48_642_975, 50_657_312, 100_000_000] {
            for amount: Int64 in [50_000_000, 100_000_000] {
                let p = try plan([coin(100_000_000)], amount: amount, rate: rate)
                let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
                XCTAssertEqual(signed.fee, p.fee)
                XCTAssertEqual(try BitcoinTransactions.txid(signed.raw, network: .dogecoin), signed.txid)
                XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(p.maximumVBytes))
            }
        }
    }
    func testImportedCompressionAndExtendedScopes() throws {
        for compression in [true,false] {
            let p = try plan([coin(100_000_000,imported:compression)],amount:50_000_000)
            _ = try BitcoinSendSigner.sign(p) { _ in .single(self.single,compressed:compression) }
        }
        let vectors = try DogecoinVectors.load()
        for key in vectors.scopes.flatMap({ [$0.dogecoin,$0.bitcoin] }) {
            for branch in try DogecoinKeys.extended(key).branches {
                let a = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
                _ = try BitcoinSendSigner.sign(plan([coin(100_000_000,derived:a)],amount:50_000_000)) { _ in .extended(key) }
            }
        }
    }
    func testWalletAggregateExceedsTransactionBoundAndRejectsOverflow() throws {
        let large = try coin(900_000_000_000_000_000)
        let p = try plan([large,coin(900_000_000_000_000_000,index:1)],amount:800_000_000_000_000_000)
        XCTAssertEqual(p.coins.count,1); XCTAssertEqual(p.walletBalance,1_800_000_000_000_000_000)
        try p.validate(); _ = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
        XCTAssertThrowsError(try plan([large],amount:UTXONetwork.dogecoin.maximumOutput+1))
        XCTAssertThrowsError(try BitcoinSendPlan.sum([Int64.max,1],maximumMoney:Int64.max))
        XCTAssertThrowsError(try plan([coin(UTXONetwork.dogecoin.maximumOutput+1)],amount:100_000_000))
    }
    func testDuplicateForgedExpiredWrongKeyAndMutatedReviewCannotSign() throws {
        let c = try coin(100_000_000), p = try plan([c],amount:50_000_000)
        XCTAssertThrowsError(try plan([c,c],amount:50_000_000))
        XCTAssertThrowsError(try plan([.init(accountID:c.accountID,txid:c.txid,vout:0,value:c.value+1,address:c.address,previousTransaction:c.previousTransaction)],amount:50_000_000))
        XCTAssertThrowsError(try p.validate(now:p.createdAt.addingTimeInterval(121)))
        XCTAssertThrowsError(try BitcoinSendSigner.sign(p) { _ in .seed(Data(repeating:1,count:32),account:0) })
        for key in ["fee","recipientAmount","changeAmount","walletBalance","maximumVBytes"] {
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
            json[key] = key == "walletBalance" ? 0 : Int64.max
            let changed = try JSONDecoder().decode(BitcoinSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertThrowsError(try BitcoinSendSigner.sign(changed) { _ in .seed(self.seed,account:0) })
        }
        for rate: Int64 in [0,999_999,100_000_001,Int64.max] { XCTAssertThrowsError(try plan([c],amount:50_000_000,rate:rate)) }
    }
    func testProviderFeeFallbackFloorRoundingAndIdenticalBroadcast() async throws {
        for (estimate,relay,expected) in [(JSONValue.integer(-1),JSONValue.decimal(0.001),Int64(1_000_000)),
                                         (.decimal(0.010000001),.decimal(0.001),1_000_001),(.decimal(1),.decimal(0.001),100_000_000)] {
            let pool = ElectrumPool(servers:[.init("test")],network:.dogecoin) { _ in StubTransport(.fee(estimate,relay),network:.dogecoin) }
            let actual = try await pool.bitcoinFeeRate(); XCTAssertEqual(actual,expected); await pool.close()
        }
        let p = try plan([coin(100_000_000)],amount:50_000_000)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
        let pool = ElectrumPool(servers:[.init("wrong"),.init("healthy")],maximumConnections:1,network:.dogecoin) {
            StubTransport(.broadcast($0.host == "wrong" ? String(repeating:"0",count:64) : signed.txid),network:.dogecoin)
        }
        let hash = try await pool.broadcastBitcoin(signed.raw); XCTAssertEqual(hash,signed.txid)
        let attempts = await pool.diagnostics(); XCTAssertEqual(attempts.map(\.error),[.invalidResponse,nil]); await pool.close()
    }
    func testLiveDogecoinMainnetFeeReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGE_LIVE_FEE"] == "1" else { throw XCTSkip("Read-only fee opt-in") }
        let pool = ElectrumPool(network:.dogecoin)
        let rate = try await pool.bitcoinFeeRate(); XCTAssertTrue(UTXONetwork.dogecoin.sendFeeRates.contains(rate)); await pool.close()
        print("Dogecoin mainnet fee validated; no mainnet transaction submitted")
    }
    func testLiveFeeCanSignReviewedDogecoinTransactionOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_FEES_LIVE"] == "1" else { throw XCTSkip("Live rate with synthetic never-funded transaction") }
        let rate = try await UTXOFeeProvider().rate(for: .dogecoin)
        let p = try plan([coin(100_000_000)], amount: 50_000_000, rate: rate)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
        XCTAssertEqual(signed.fee, p.fee)
        XCTAssertEqual(try BitcoinTransactions.txid(signed.raw, network: .dogecoin), signed.txid)
        print("Live DOGE fee \(rate) atomic/kB signed offline within the exact reviewed fee budget; not broadcast")
    }
    func testPrepareIsolatedPublicTestWallet() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_DOGE_TESTNET_DIR"] else { throw XCTSkip("Public Dogecoin testnet opt-in") }
        let root = URL(fileURLWithPath:directory,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path = root.appendingPathComponent("test-seed.bin")
        if !FileManager.default.fileExists(atPath:path.path) {
            try Data((0..<32).map { _ in UInt8.random(in:0...255) }).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        var seed = try Data(contentsOf:path); defer { seed.resetBytes(in:0..<seed.count) }
        let branch = try DogecoinKeys.wallet(seed:seed).branches.first { $0.type == .legacy && $0.change == 0 }!
        let a = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
        let address = try BitcoinSendPlan.address(a,on:.testnet,chain:.dogecoin)
        // Do not reset the live sequence when the preparation test is rerun.
        let existing = (try? Data(contentsOf:root.appendingPathComponent("public.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        if existing == nil || (existing?["step"] == nil && existing?["scriptHash"] == nil) {
            try JSONSerialization.data(withJSONObject:["address":address,"scriptHash":a.scriptHash,"type":44,"change":0,"index":0],options:.prettyPrinted)
                .write(to:root.appendingPathComponent("public.json"))
        }
        print("Isolated Dogecoin testnet funding address: " + address)
    }

    func testSignPublicTestnetTransfer() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_DOGE_PUBLIC_SIGN_DIR"] else { throw XCTSkip("Isolated public Dogecoin signing opt-in") }
        let root = URL(fileURLWithPath:directory,isDirectory:true)
        let info = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("public.json"))) as! [String:Any]
        let step = info["step"] as? Int ?? 0
        guard step < 6 else { throw XCTSkip("Six public transfers already completed") }
        var seed = try Data(contentsOf:root.appendingPathComponent("test-seed.bin")); defer { seed.resetBytes(in:0..<seed.count) }
        let wallet = try DogecoinKeys.wallet(seed:seed)
        func derived(_ type: BitcoinAddressType,_ change: UInt32,_ index: UInt32) throws -> BitcoinDerivedAddress {
            let branch = wallet.branches.first { $0.type == type && $0.change == change }!
            return try BitcoinKeys.addresses(branch:branch,range:index..<(index+1))[0]
        }
        let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("utxos.json"))) as! [[String:Any]]
        let coins = try rows.map { row in
            BitcoinSendCoin(accountID:"isolated",txid:row["tx_hash"] as! String,vout:row["tx_pos"] as! Int,value:(row["value"] as! NSNumber).int64Value,
                address:try derived(BitcoinAddressType(rawValue:row["type"] as! Int)!,UInt32(row["change"] as! Int),UInt32(row["index"] as! Int)),
                previousTransaction:Data(hex:row["raw"] as! String)!)
        }
        let type: BitcoinAddressType = [.legacy,.legacy,.legacy,.legacy,.legacy,.legacy][step]
        let target = try derived(type,UInt32(step%2),UInt32(10+step))
        let change = try derived(.legacy,1,UInt32(30+step))
        let address = try BitcoinSendPlan.address(target,on:.testnet,chain:.dogecoin)
        let total = try BitcoinSendPlan.sum(coins.map(\.value),maximumMoney:UTXONetwork.dogecoin.maximumMoney)
        let p = try BitcoinSendPlan.make(coins:coins,recipient:address,amount:step == 0 ? total/2 : total,
                                         change:change,ratePerKVByte:1_000_000,network:.testnet,chain:.dogecoin)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(seed,account:0) }
        func publicAddress(_ a: BitcoinDerivedAddress) throws -> [String:Any] {
            ["address":try BitcoinSendPlan.address(a,on:.testnet,chain:.dogecoin),"scriptHash":a.scriptHash,"type":a.type.rawValue,"change":a.change,"index":a.index]
        }
        var next = try [publicAddress(target)]
        if p.changeAmount > 0 { next.append(try publicAddress(change)) }
        try JSONSerialization.data(withJSONObject:["network":"dogecoin-testnet","step":step,"raw":signed.raw.hex,"txid":signed.txid,
            "fee":p.fee,"inputs":p.coins.count,"nextAddresses":next],options:.prettyPrinted).write(to:root.appendingPathComponent("signed.json"))
        print("Signed isolated Dogecoin testnet step \(step); broadcast is separate")
    }


    func testCoreMinesP2PKHAndP2SHMixedPathsCompressionAndDust() throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGE_REGTEST"] == "1" else { throw XCTSkip("Dogecoin Core isolated regtest opt-in") }
        let rpc = DogecoinNodeRPC()
        XCTAssertEqual((try rpc.call("getblockchaininfo",[]) as! [String:Any])["chain"] as? String,"regtest")
        _ = try rpc.call("generate",[241])
        let pkh = try BitcoinSendPlan.address(address(index:9000),on:.regtest,chain:.dogecoin)
        let sh = try DogecoinAddress.encode(script:Data([0xa9,20])+Data(repeating:7,count:20)+Data([0x87]),network:.regtest)
        var receipts: [[String:Any]] = [], counter: UInt32 = 1000
        let compressed = try imported(true), uncompressed = try imported(false)
        func send(_ addresses: [BitcoinDerivedAddress], value: Int64, amount: Int64, destination: String) throws {
            let outputs = try Dictionary(uniqueKeysWithValues:addresses.map { (try BitcoinSendPlan.address($0,on:.regtest,chain:.dogecoin),NSDecimalNumber(decimal:Decimal(value)/100_000_000).stringValue) })
            let hash = try rpc.call("sendmany",["",outputs]) as! String
            _ = try rpc.call("generate",[1])
            let raw = Data(hex:try rpc.call("getrawtransaction",[hash]) as! String)!
            let funding = try BitcoinTransactions.details(raw,network:.dogecoin)
            let coins = addresses.map { a in BitcoinSendCoin(accountID:a == compressed ? "compressed":a == uncompressed ? "uncompressed":"hd",txid:hash,
                vout:funding.outputs.firstIndex { $0.script == a.script }!,value:value,address:a,previousTransaction:raw,compressed:a != uncompressed) }
            let p = try BitcoinSendPlan.make(coins:coins,recipient:destination,amount:amount,change:address(change:1),ratePerKVByte:1_000_000,network:.regtest,chain:.dogecoin)
            let signed = try BitcoinSendSigner.sign(p) { id in id == "hd" ? .seed(self.seed,account:0) : .single(self.single,compressed:id == "compressed") }
            // Core 1.14 has no testmempoolaccept. Submit a tampered signature
            // commitment and assert rejection, then submit the intact payload.
            if receipts.isEmpty {
                var modified = signed.raw
                let amountBytes = BitcoinWire.little(UInt64(p.recipientAmount)) + BitcoinWire.vector(p.recipientScript)
                let range = try XCTUnwrap(modified.range(of:amountBytes)); modified[range.lowerBound] -= 1
                XCTAssertThrowsError(try rpc.call("sendrawtransaction",[modified.hex]))
            }
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            _ = try rpc.call("generate",[1])
            let fetched = try rpc.call("getrawtransaction",[signed.txid,1]) as! [String:Any]
            XCTAssertEqual(fetched["hex"] as? String,signed.raw.hex); XCTAssertGreaterThan(fetched["confirmations"] as! Int,0)
            let decoded = try rpc.call("decoderawtransaction",[signed.raw.hex]) as! [String:Any]
            let vout = decoded["vout"] as! [[String:Any]]
            let actualRecipient = NSDecimalNumber(string:String(describing:vout[0]["value"]!)).multiplying(by:100_000_000).int64Value
            XCTAssertEqual(actualRecipient,p.recipientAmount)
            receipts.append(["txid":signed.txid,"inputs":p.coins.count,"fee":p.fee,"recipient":p.recipientAmount,"change":p.changeAmount,"bytes":signed.virtualBytes,"destination":destination])
        }
        for target in [pkh,sh] {
            for path: UInt32 in [0,1] {
                try send([address(change:path,index:counter)],value:100_000_000,amount:50_000_000,destination:target);counter += 1
            }
            for source in [compressed,uncompressed] { try send([source],value:100_000_000,amount:50_000_000,destination:target) }
            let mixed = try (0..<253).map { try address(change:UInt32($0%2),index:UInt32(2000+$0)) } + [compressed,uncompressed]
            try send(mixed,value:2_000_000,amount:510_000_000,destination:target)
            for amount: Int64 in [100_000_000,99_999_999,99_700_000,98_500_000,100_000,999_999,1_000_000] {
                try send([address(index:counter)],value:100_000_000,amount:amount,destination:target);counter += 1
            }
        }
        XCTAssertEqual(receipts.count,24)
        try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/oath-doge-regtest-receipts.json"))
        print("Dogecoin Core: 24 transactions accepted, retried identically and mined, including 255 mixed inputs to P2PKH and P2SH")
    }

}

private struct DogecoinNodeRPC {
    func call(_ method: String,_ params: [Any]) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath:"/opt/homebrew/bin/docker")
        process.arguments = ["exec","oath-doge-send-regtest","/doge/dogecoin-cli","-regtest","-rpcuser=oathregtest","-rpcpassword=isolated-test-only",method] + (try params.map { value in
            if let string = value as? String { return string }
            return String(data:try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed),encoding:.utf8)!
        })
        process.standardOutput = out; process.standardError = err
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"DogecoinNodeRPC."+method,code:Int(process.terminationStatus)) }
        return (try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) ?? String(data:data,encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
