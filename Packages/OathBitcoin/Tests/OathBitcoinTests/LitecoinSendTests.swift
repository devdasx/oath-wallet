import Foundation
import XCTest
@testable import OathBitcoin

final class LitecoinSendTests: XCTestCase {
    // Published, deterministic test material. Never used on mainnet.
    let seed = Data(0..<32)
    func address(_ type: BitcoinAddressType = .nativeSegwit, change: UInt32 = 0, index: UInt32 = 0) throws -> BitcoinDerivedAddress {
        let branch = try LitecoinKeys.wallet(seed: seed).branches.first { $0.type == type && $0.change == change }!
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
    }
    func coin(_ value: Int64, type: BitcoinAddressType = .nativeSegwit, index: UInt32 = 0,
              change: UInt32 = 0, compressed: Bool = true) throws -> BitcoinSendCoin {
        let a = try compressed ? address(type, change: change, index: index) : BitcoinKeys.addresses(
            branch: LitecoinKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false).branches[0], range: 0..<1)[0]
        // Synthetic funding transaction for pure signing tests; Core tests below
        // use real mined/funded transactions instead.
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(index) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(value)) + BitcoinWire.vector(Data(hex: a.script)!)
        raw += BitcoinWire.little(UInt32(0))
        return .init(accountID: "test", txid: try BitcoinTransactions.txid(raw, network: .litecoin), vout: 0, value: value,
                     address: a, previousTransaction: raw, compressed: compressed)
    }
    func plan(_ coins: [BitcoinSendCoin], amount: Int64, rate: Int64 = 2000) throws -> BitcoinSendPlan {
        try .make(coins: coins, recipient: address(.taproot, index: 12).address, amount: amount,
                  change: address(change: 1), ratePerKVByte: rate, chain: .litecoin)
    }

    func testAddressesAllTypesNetworksAliasesAndChecksums() throws {
        for type in BitcoinAddressType.allCases {
            let a = try address(type), script = Data(hex: a.script)!
            XCTAssertEqual(try BitcoinSendPlan.recipientScript(a.address, chain: .litecoin), script)
            for network in [BitcoinSendNetwork.mainnet, .testnet, .regtest] {
                let value = try BitcoinSendPlan.address(a, on: network, chain: .litecoin)
                XCTAssertEqual(try BitcoinSendPlan.recipientScript(value, chain: .litecoin, network: network), script)
                XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(value + "q", chain: .litecoin, network: network))
                if type == .nativeSegwit || type == .taproot {
                    XCTAssertEqual(try BitcoinSendPlan.recipientScript(value.uppercased(), chain: .litecoin, network: network), script)
                    XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(value.prefix(1).uppercased() + value.dropFirst(), chain: .litecoin, network: network))
                }
            }
            let bitcoin = try BitcoinSendPlan.address(a, on: .mainnet)
            if type != .nestedSegwit { XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(bitcoin, chain: .litecoin)) }
            else { XCTAssertEqual(try BitcoinSendPlan.recipientScript(bitcoin, chain: .litecoin), script) }
            let testnet = try BitcoinSendPlan.address(a, on: .testnet, chain: .litecoin)
            XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(testnet, chain: .litecoin))
            XCTAssertThrowsError(try BitcoinSendPlan.address(a, on: .chipnet, chain: .litecoin))
        }
        XCTAssertThrowsError(try BitcoinSendPlan.recipientScript("ltcmweb1nottransparent", chain: .litecoin))
    }
    func testMixedTypesBothPathsAndAllRecipientsSign() throws {
        let coins = try BitcoinAddressType.allCases.enumerated().flatMap { offset, type in
            try [coin(20_000, type: type, index: UInt32(offset)), coin(20_000, type: type, index: UInt32(offset + 4), change: 1)]
        }
        for target in BitcoinAddressType.allCases {
            let p = try BitcoinSendPlan.make(coins: coins, recipient: address(target, index: 15).address, amount: 160_000,
                                            change: address(change: 1), ratePerKVByte: 2000, chain: .litecoin)
            XCTAssertEqual(p.coins.count, 8)
            let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
            XCTAssertEqual(try BitcoinTransactions.txid(signed.raw, network: .litecoin), signed.txid)
            XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(p.maximumVBytes))
        }
    }
    func testLitecoinDustAndFeeFromRemainderThenAmount() throws {
        let normal = try plan([coin(100_000)], amount: 50_000)
        XCTAssertEqual(normal.recipientAmount, 50_000)
        XCTAssertEqual(normal.deductedFromAmount, 0)
        for amount: Int64 in [100_000, 99_999] {
            let p = try plan([coin(100_000)], amount: amount)
            XCTAssertEqual(p.changeAmount, 0)
            XCTAssertEqual(p.recipientAmount, 100_000 - p.fee)
            XCTAssertEqual(p.deductedFromAmount, amount - p.recipientAmount)
        }
        let tiny = try plan([coin(100_000), coin(100, index: 1)], amount: 99_700, rate: 1000)
        XCTAssertEqual(tiny.coins.count, 1); XCTAssertEqual(tiny.remainingBalance, 100)
        for (type, threshold) in [(BitcoinAddressType.legacy, Int64(5460)), (.nestedSegwit,5400), (.nativeSegwit,2940), (.taproot,3300)] {
            let a = try address(type)
            XCTAssertEqual(BitcoinSendPlan.dust(Data(hex:a.script)!, chain:.litecoin), threshold)
            XCTAssertThrowsError(try BitcoinSendPlan.make(coins:[coin(100_000)],recipient:a.address,amount:threshold-1,
                                                        change:address(change:1),ratePerKVByte:1000,chain:.litecoin))
            let p = try BitcoinSendPlan.make(coins:[coin(100_000)],recipient:a.address,amount:threshold,
                                             change:address(change:1),ratePerKVByte:1000,chain:.litecoin)
            try p.validate()
        }
    }
    func testSupplyLimitDoesNotUseBitcoinsTwentyOneMillion() throws {
        let p = try plan([coin(2_500_000_000_000_000)], amount: 2_500_000_000_000_000)
        try p.validate()
        _ = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account:0) }
        XCTAssertThrowsError(try plan([coin(UTXONetwork.litecoin.maximumMoney + 1)], amount: 50_000))
    }
    func testManyMixedInputsAndUncompressedImport() throws {
        let coins = try (0..<255).map { try coin(20_000,type:BitcoinAddressType.allCases[$0%4],index:UInt32($0),change:UInt32($0%2)) }
        let p = try plan(coins, amount: 5_100_000, rate: 1000)
        XCTAssertEqual(p.coins.count,255)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
        XCTAssertLessThanOrEqual(signed.virtualBytes,UInt64(p.maximumVBytes))
        let imported = try plan([coin(100_000,type:.legacy,compressed:false)],amount:50_000)
        _ = try BitcoinSendSigner.sign(imported) { _ in .single(Data(repeating:0,count:31)+Data([1]),compressed:false) }
    }
    func testWrongKeyForgedParentExpiredAndTamperedReviewCannotSign() throws {
        let c = try coin(100_000), p = try plan([c],amount:50_000)
        XCTAssertThrowsError(try plan([c,c],amount:50_000))
        XCTAssertThrowsError(try plan([.init(accountID:c.accountID,txid:c.txid,vout:0,value:c.value+1,address:c.address,previousTransaction:c.previousTransaction)],amount:50_000))
        XCTAssertThrowsError(try p.validate(now:p.createdAt.addingTimeInterval(121)))
        XCTAssertThrowsError(try BitcoinSendSigner.sign(p) { _ in .seed(Data(repeating:1,count:32),account:0) })
        for key in ["fee","recipientAmount","changeAmount","walletBalance","maximumVBytes"] {
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
            json[key] = Int64.max
            let changed = try JSONDecoder().decode(BitcoinSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertThrowsError(try BitcoinSendSigner.sign(changed) { _ in .seed(self.seed,account:0) })
        }
    }
    func testMWEBParentIsNormalizedWithoutChangingTransparentCommitment() throws {
        let c = try coin(100_000), raw = c.previousTransaction
        let extended = raw.prefix(4) + Data([0,8]) + raw.dropFirst(4).dropLast(4) + Data([0]) + raw.suffix(4)
        let mweb = BitcoinSendCoin(accountID:c.accountID,txid:c.txid,vout:c.vout,value:c.value,address:c.address,previousTransaction:extended)
        let p = try plan([mweb],amount:50_000)
        _ = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
    }
    func testExtendedPrivateImportsAcrossSupportedScopesSign() throws {
        let vectors = try LitecoinVectors.load()
        var signed = 0
        for scope in vectors.scopes {
            for key in scope.keys.values where (try? LitecoinKeys.decodeImport(key).extended) != nil {
                let wallet = try LitecoinKeys.extended(key)
                for branch in wallet.branches {
                    let a = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
                    let original = try coin(100_000)
                    var raw = original.previousTransaction.prefix(55)
                    raw += BitcoinWire.vector(Data(hex:a.script)!) + BitcoinWire.little(UInt32(0))
                    let c = BitcoinSendCoin(accountID:"extended",txid:try BitcoinTransactions.txid(raw,network:.litecoin),vout:0,value:100_000,address:a,previousTransaction:raw)
                    _ = try BitcoinSendSigner.sign(plan([c],amount:50_000)) { _ in .extended(key) }
                    signed += 1
                }
            }
        }
        XCTAssertGreaterThan(signed,20)
    }
    func testFeeAndBroadcastProvidersMustMatchChainAndTransaction() async throws {
        let p = try plan([coin(100_000)],amount:50_000)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) }
        let pool = ElectrumPool(servers:[.init("wrong"),.init("healthy")],maximumConnections:1,network:.litecoin) {
            StubTransport(.broadcast($0.host == "wrong" ? String(repeating:"0",count:64) : signed.txid),network:.litecoin)
        }
        let result = try await pool.broadcastBitcoin(signed.raw)
        XCTAssertEqual(result,signed.txid)
        let attempts = await pool.diagnostics(); XCTAssertEqual(attempts.map(\.error),[.invalidResponse,nil]); await pool.close()
        let fees = ElectrumPool(servers:[.init("bad"),.init("healthy")],maximumConnections:1,network:.litecoin) {
            StubTransport($0.host == "bad" ? .fee(.null,.decimal(0.00001)) : .fee(.integer(-1),.decimal(0.00002)),network:.litecoin)
        }
        let rate = try await fees.bitcoinFeeRate(); XCTAssertEqual(rate,2000); await fees.close()
    }
    func testPrepareIsolatedPublicTestWallet() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_LTC_TESTNET_DIR"] else { throw XCTSkip("Public Litecoin testnet opt-in") }
        let root = URL(fileURLWithPath:directory,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path = root.appendingPathComponent("test-seed.bin")
        if !FileManager.default.fileExists(atPath:path.path) {
            try Data((0..<32).map { _ in UInt8.random(in:0...255) }).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        var seed = try Data(contentsOf:path); defer { seed.resetBytes(in:0..<seed.count) }
        let branch = try LitecoinKeys.wallet(seed:seed).branches.first { $0.type == .nativeSegwit && $0.change == 0 }!
        let a = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
        let address = try BitcoinSendPlan.address(a,on:.testnet,chain:.litecoin)
        // Do not reset the live sequence when the preparation test is rerun.
        let existing = (try? Data(contentsOf:root.appendingPathComponent("public.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        if existing == nil || (existing?["step"] == nil && existing?["scriptHash"] == nil) {
            try JSONSerialization.data(withJSONObject:["address":address,"scriptHash":a.scriptHash,"type":84,"change":0,"index":0],options:.prettyPrinted)
                .write(to:root.appendingPathComponent("public.json"))
        }
        print("Isolated Litecoin testnet funding address: " + address)
    }

    func testLiveLitecoinMainnetFeeReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LTC_LIVE_FEE"] == "1" else { throw XCTSkip("Opt-in live read-only fee lookup") }
        let pool = ElectrumPool(network: .litecoin)
        let rate = try await pool.bitcoinFeeRate()
        XCTAssertTrue((1000...1_000_000).contains(rate))
        await pool.close()
        print("Litecoin mainnet fee quote validated; no mainnet transaction submitted")
    }

    func testSignPublicTestnetTransfer() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_LTC_PUBLIC_SIGN_DIR"] else { throw XCTSkip("Isolated public Litecoin signing opt-in") }
        let root = URL(fileURLWithPath:directory,isDirectory:true)
        let info = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("public.json"))) as! [String:Any]
        let step = info["step"] as? Int ?? 0
        guard step < 6 else { throw XCTSkip("Six public transfers already completed") }
        var seed = try Data(contentsOf:root.appendingPathComponent("test-seed.bin")); defer { seed.resetBytes(in:0..<seed.count) }
        let wallet = try LitecoinKeys.wallet(seed:seed)
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
        let type: BitcoinAddressType = [.legacy,.nativeSegwit,.taproot,.nestedSegwit,.legacy,.nativeSegwit][step]
        let target = try derived(type,UInt32(step%2),UInt32(10+step))
        let change = try derived(.nestedSegwit,1,UInt32(30+step))
        let address = try BitcoinSendPlan.address(target,on:.testnet,chain:.litecoin)
        let total = try BitcoinSendPlan.sum(coins.map(\.value),maximumMoney:UTXONetwork.litecoin.maximumMoney)
        let p = try BitcoinSendPlan.make(coins:coins,recipient:address,amount:step == 0 ? total/2 : total,
                                         change:change,ratePerKVByte:2000,network:.testnet,chain:.litecoin)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(seed,account:0) }
        func publicAddress(_ a: BitcoinDerivedAddress) throws -> [String:Any] {
            ["address":try BitcoinSendPlan.address(a,on:.testnet,chain:.litecoin),"scriptHash":a.scriptHash,"type":a.type.rawValue,"change":a.change,"index":a.index]
        }
        var next = try [publicAddress(target)]
        if p.changeAmount > 0 { next.append(try publicAddress(change)) }
        try JSONSerialization.data(withJSONObject:["network":"litecoin-testnet","step":step,"raw":signed.raw.hex,"txid":signed.txid,
            "fee":p.fee,"inputs":p.coins.count,"nextAddresses":next],options:.prettyPrinted).write(to:root.appendingPathComponent("signed.json"))
        print("Signed isolated Litecoin testnet step \(step); broadcast is separate")
    }

    func testCoreAcceptsMinesMixedAddressAndDustMatrix() throws {
        guard ProcessInfo.processInfo.environment["OATH_LTC_REGTEST"] == "1" else { throw XCTSkip("Litecoin Core isolated regtest opt-in") }
        let rpc = LitecoinNodeRPC()
        _ = try? rpc.call("createwallet",["oath-ltc-send"])
        let mining = try rpc.call("getnewaddress",[]) as! String
        _ = try rpc.call("generatetoaddress",[101,mining])
        let importedKey = Data(repeating:0,count:31)+Data([1])
        let imported = try BitcoinKeys.addresses(branch:LitecoinKeys.singleKey(bytes:importedKey,compressed:false).branches[0],range:0..<1)[0]
        var receipts: [[String:Any]] = [], counter: UInt32 = 1000
        func send(_ addresses: [BitcoinDerivedAddress], value: Int64, amount: Int64, destination: String) throws {
            let outputs = try Dictionary(uniqueKeysWithValues:addresses.map { (try BitcoinSendPlan.address($0,on:.regtest,chain:.litecoin),NSDecimalNumber(decimal:Decimal(value)/100_000_000).stringValue) })
            let hash = try rpc.call("sendmany",["",outputs]) as! String
            _ = try rpc.call("generatetoaddress",[1,mining])
            let raw = Data(hex:try rpc.call("getrawtransaction",[hash]) as! String)!
            let funding = try BitcoinTransactions.details(raw,network:.litecoin)
            let coins = addresses.map { a in BitcoinSendCoin(accountID:a == imported ? "import":"hd",txid:hash,
                vout:funding.outputs.firstIndex { $0.script == a.script }!,value:value,address:a,previousTransaction:raw,compressed:a != imported) }
            let p = try BitcoinSendPlan.make(coins:coins,recipient:destination,amount:amount,change:address(change:1),ratePerKVByte:1000,network:.regtest,chain:.litecoin)
            let signed = try BitcoinSendSigner.sign(p) { $0 == "import" ? .single(importedKey,compressed:false) : .seed(self.seed,account:0) }
            let check = try rpc.call("testmempoolaccept",[[signed.raw.hex]]) as! [[String:Any]]
            XCTAssertEqual(check[0]["allowed"] as? Bool,true,"Litecoin Core rejected: \(check[0]["reject-reason"] ?? "unknown")")
            guard check[0]["allowed"] as? Bool == true else { throw BitcoinSendError.signing }
            // The reviewed recipient amount is committed by every signature.
            if receipts.isEmpty {
                var modified = signed.raw
                let amountBytes = BitcoinWire.little(UInt64(p.recipientAmount)) + BitcoinWire.vector(p.recipientScript)
                let range = try XCTUnwrap(modified.range(of:amountBytes)); modified[range.lowerBound] -= 1
                let rejected = try rpc.call("testmempoolaccept",[[modified.hex]]) as! [[String:Any]]
                XCTAssertEqual(rejected[0]["allowed"] as? Bool,false)
                XCTAssertTrue((rejected[0]["reject-reason"] as? String)?.contains("script") == true, "Unexpected rejection: \(rejected[0]["reject-reason"] ?? "unknown")")
            }
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            _ = try rpc.call("generatetoaddress",[1,mining])
            let fetched = try rpc.call("getrawtransaction",[signed.txid,true]) as! [String:Any]
            XCTAssertEqual(fetched["hex"] as? String,signed.raw.hex); XCTAssertGreaterThan(fetched["confirmations"] as! Int,0)
            receipts.append(["txid":signed.txid,"inputs":p.coins.count,"fee":p.fee,"recipient":p.recipientAmount,"change":p.changeAmount,"vsize":signed.virtualBytes])
        }
        let targets = try BitcoinAddressType.allCases.map { try BitcoinSendPlan.address(address($0,index:9000),on:.regtest,chain:.litecoin) }
        for target in targets {
            for source in BitcoinAddressType.allCases {
                for path: UInt32 in [0,1] {
                    try send([address(source,change:path,index:counter)],value:100_000,amount:50_000,destination:target);counter += 1
                }
            }
            try send([imported],value:100_000,amount:50_000,destination:target)
        }
        let mixed = try (0..<254).map { try address(BitcoinAddressType.allCases[$0%4],change:UInt32(($0/4)%2),index:UInt32(2000+$0)) } + [imported]
        try send(mixed,value:20_000,amount:5_100_000,destination:targets[0])
        for amount: Int64 in [100_000,99_999,99_700,95_000,5_460] {
            try send([address(.legacy,index:counter)],value:100_000,amount:amount,destination:targets[0]);counter += 1
        }
        // Legacy P2SH aliases and a native P2WSH recipient.
        let nested = try address(.nestedSegwit,index:9001)
        let alias = Base58Check.encode(Data([196])+Data(hex:nested.script)!.dropFirst(2).prefix(20))
        let wsh = SegwitAddress.encode(hrp:"rltc",version:0,program:Data(repeating:7,count:32))
        for destination in [alias,wsh] {
            try send([address(index:counter)],value:100_000,amount:50_000,destination:destination);counter += 1
        }
        XCTAssertEqual(receipts.count,44)
        try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/oath-ltc-regtest-receipts.json"))
        print("Litecoin Core: 44 transactions accepted, retried identically and mined, including 255 mixed inputs")
    }

}

private struct LitecoinNodeRPC {
    func call(_ method: String,_ params: [Any]) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath:"/opt/homebrew/bin/docker")
        process.arguments = ["exec","oath-ltc-send-regtest","/ltc/litecoin-cli","-regtest","-datadir=/data","-rpcwallet=oath-ltc-send",method] + (try params.map { value in
            if let string = value as? String { return string }
            return String(data:try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed),encoding:.utf8)!
        })
        process.standardOutput = out; process.standardError = err
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"LitecoinNodeRPC."+method,code:Int(process.terminationStatus)) }
        return (try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) ?? String(data:data,encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
