import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinCashSendTests: XCTestCase {
    let seed = Data(0..<32) // Public fixture, never a production wallet.
    func address(change: UInt32 = 0, index: UInt32 = 0, account: UInt32 = 0) throws -> BitcoinDerivedAddress {
        let branch = try BitcoinCashKeys.wallet(seed: seed, account: account).branches.first { $0.change == change }!
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index+1))[0]
    }
    func funding(_ address: BitcoinDerivedAddress, value: Int64, nonce: UInt32 = 0, compressed: Bool = true, account: String = "hd") throws -> BitcoinSendCoin {
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(nonce) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(value)) + BitcoinWire.vector(Data(hex: address.script)!) + BitcoinWire.little(UInt32(0))
        return .init(accountID: account, txid: try BitcoinTransactions.txid(raw, network: .bitcoincash), vout: 0,
                     value: value, address: address, previousTransaction: raw, compressed: compressed)
    }
    func plan(_ coins: [BitcoinSendCoin], amount: Int64, recipient: String? = nil, network: BitcoinSendNetwork = .mainnet) throws -> BitcoinSendPlan {
        try .make(coins: coins, recipient: recipient ?? BitcoinSendPlan.address(address(index: 100), on: network, chain: .bitcoincash),
                  amount: amount, change: address(change: 1), ratePerKVByte: 1000, network: network, chain: .bitcoincash)
    }
    func testCashAddrAndLegacyChecksumsNetworkAndScriptTypes() throws {
        let legacy = "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", cash = "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        let script = try BitcoinSendPlan.recipientScript(legacy, chain: .bitcoincash)
        for text in [cash, cash.uppercased(), String(cash.split(separator: ":")[1])] {
            XCTAssertEqual(try BitcoinSendPlan.recipientScript(text, chain: .bitcoincash), script)
        }
        for script in [script, Data([0xa9,20]) + Data(repeating: 7,count:20) + Data([0x87]),
                       Data([0xaa,32]) + Data(repeating: 7,count:32) + Data([0x87])] {
            for prefix in ["bitcoincash","bchtest","bchreg"] {
                XCTAssertEqual(try CashAddress.decode(CashAddress.encode(script: script,prefix:prefix),prefix:prefix), script)
            }
        }
        for bad in [cash + "q", "Bitcoincash:" + cash.split(separator: ":")[1], cash.replacingOccurrences(of:"bitcoincash",with:"bchtest"),
                    "bitcoincash:", "::", "bc1qnotbch"] {
            XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(bad,chain:.bitcoincash))
        }
        XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(cash,chain:.bitcoincash,network:.testnet4))
    }
    func testFeesFromRemainderThenAmountDustAndTinyWalletRemainder() throws {
        let coin = try funding(address(),value:100_000)
        let normal = try plan([coin],amount:50_000)
        XCTAssertEqual(normal.recipientAmount,50_000); XCTAssertGreaterThanOrEqual(normal.changeAmount,546)
        for amount: Int64 in [100_000,99_999] {
            let sweep = try plan([coin],amount:amount)
            XCTAssertEqual(sweep.changeAmount,0); XCTAssertEqual(sweep.total,100_000)
            XCTAssertEqual(sweep.deductedFromAmount,amount - (100_000 - sweep.fee))
        }
        let tiny = try plan([coin,funding(address(index:1),value:100,nonce:1)],amount:99_700)
        XCTAssertEqual(tiny.coins.count,1); XCTAssertEqual(tiny.remainingBalance,100); XCTAssertEqual(tiny.fee,300)
        XCTAssertThrowsError(try plan([coin],amount:545))
    }
    func testMixedAccountsReceiveChangeAndImportedKeysSign() throws {
        let key = Data(repeating:0,count:31)+Data([1])
        let uncompressed = try BitcoinKeys.addresses(branch:BitcoinCashKeys.singleKey(bytes:key,compressed:false).branches[0],range:0..<1)[0]
        let coins = try [funding(address(),value:20_000),funding(address(change:1,index:8),value:20_000,nonce:1),
                         funding(address(account:1),value:20_000,nonce:2,account:"second"),
                         funding(uncompressed,value:20_000,nonce:3,compressed:false,account:"import")]
        let p = try plan(coins,amount:80_000)
        let signed = try BitcoinCashSendSigner.sign(p) { id in
            if id == "import" { return .single(key,compressed:false) }
            return .seed(self.seed,account:id == "second" ? 1 : 0)
        }
        XCTAssertEqual(try BitcoinTransactions.details(signed.raw,network:.bitcoincash).inputs.count,4)
        XCTAssertLessThanOrEqual(Int64(signed.raw.count),p.maximumVBytes)
        XCTAssertThrowsError(try BitcoinSendSigner.sign(p) { _ in .seed(self.seed,account:0) })
    }
    func testExtendedPrivateImportsAcrossAllScopesCanSign() throws {
        let vectors = try BitcoinCashVectors.load()
        for scope in vectors.scopes {
            let wallet = try BitcoinCashKeys.extended(scope.private)
            for branch in wallet.branches {
                let a = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
                let coin = try funding(a,value:20_000)
                let p = try plan([coin],amount:10_000)
                _ = try BitcoinCashSendSigner.sign(p) { _ in .extended(scope.private) }
            }
        }
    }
    func testTokenBurnForgedParentWrongKeyAndModifiedReviewRejected() throws {
        let coin = try funding(address(),value:100_000)
        let raw = coin.previousTransaction
        let prefix = Data([0xef]) + Data(repeating:34,count:32) + Data([0x10,1])
        let tokenRaw = raw.prefix(55) + Data([UInt8(25+prefix.count)]) + prefix + raw.dropFirst(56)
        let token = BitcoinSendCoin(accountID:"hd",txid:try BitcoinTransactions.txid(tokenRaw,network:.bitcoincash),vout:0,
                                   value:100_000,address:coin.address,previousTransaction:tokenRaw)
        XCTAssertThrowsError(try plan([token],amount:50_000))
        XCTAssertThrowsError(try plan([coin,coin],amount:50_000))
        XCTAssertThrowsError(try plan([.init(accountID:"hd",txid:coin.txid,vout:0,value:200_000,address:coin.address,previousTransaction:raw)],amount:50_000))
        let p = try plan([coin],amount:50_000)
        XCTAssertThrowsError(try BitcoinCashSendSigner.sign(p) { _ in .seed(Data(repeating:1,count:32),account:0) })
        XCTAssertThrowsError(try p.validate(now:p.createdAt.addingTimeInterval(121)))
        for key in ["fee","recipientAmount","changeAmount","walletBalance","maximumVBytes"] {
            var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
            object[key] = Int64.max
            let tampered = try JSONDecoder().decode(BitcoinSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
            XCTAssertThrowsError(try BitcoinCashSendSigner.sign(tampered) { _ in .seed(self.seed,account:0) })
        }
    }
    func testOldBitcoinPlanStillDecodesAndSigns() throws {
        let btc = BitcoinSendTests(), p = try btc.plan([btc.coin(100_000)],amount:50_000)
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        object.removeValue(forKey:"chainValue")
        let restored = try JSONDecoder().decode(BitcoinSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(restored.chain,.bitcoin)
        _ = try BitcoinSendSigner.sign(restored) { _ in .seed(self.seed,account:0) }
    }
    func testBCHFeeFallbackRelayFloorAndMalformedProviderFailover() async throws {
        for estimate in [JSONValue.integer(-1), .decimal(-1), .decimal(0.000001)] {
            let pool = ElectrumPool(servers: [.init("verified")], network: .bitcoincash) { _ in
                StubTransport(.fee(estimate, .decimal(0.00002)), network: .bitcoincash)
            }
            let rate = try await pool.bitcoinFeeRate()
            XCTAssertEqual(rate, 2000)
            await pool.close()
        }
        for malformed in [JSONValue.null, .string("0.00001"), .integer(0), .integer(-2), .decimal(0.010001)] {
            let pool = ElectrumPool(servers: [.init("malformed"), .init("healthy")], maximumConnections: 1, network: .bitcoincash) {
                StubTransport(.fee($0.host == "malformed" ? malformed : .decimal(0.00001), .decimal(0.000001)), network: .bitcoincash)
            }
            let rate = try await pool.bitcoinFeeRate()
            XCTAssertEqual(rate, 1000)
            let attempts = await pool.diagnostics()
            XCTAssertEqual(attempts.count, 2)
            await pool.close()
        }
        let unavailable = ElectrumPool(servers: [.init("bad-relay")], network: .bitcoincash) { _ in
            StubTransport(.fee(.integer(-1), .integer(0)), network: .bitcoincash)
        }
        do { _ = try await unavailable.bitcoinFeeRate(); XCTFail("Invalid relay floor accepted") }
        catch { }
        await unavailable.close()
    }
    func testBCHBroadcastRejectsWrongTransactionIDAndRetriesIdenticalPayload() async throws {
        let p = try plan([funding(address(), value: 100_000)], amount: 50_000)
        let signed = try BitcoinCashSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
        let pool = ElectrumPool(servers: [.init("wrong"), .init("matching")], maximumConnections: 1, network: .bitcoincash) {
            StubTransport(.broadcast($0.host == "wrong" ? String(repeating: "0", count: 64) : signed.txid), network: .bitcoincash)
        }
        let returned = try await pool.broadcastBitcoin(signed.raw)
        XCTAssertEqual(returned, signed.txid)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [.invalidResponse, nil])
        await pool.close()
    }
    func testLiveBCHMainnetFeeReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BCH_LIVE_FEE"] == "1" else { throw XCTSkip("Opt-in live read-only fee lookup") }
        let pool = ElectrumPool(network:.bitcoincash)
        let rate = try await pool.bitcoinFeeRate()
        XCTAssertTrue((1000...1_000_000).contains(rate)); await pool.close()
        print("BCH mainnet fee quote validated; no mainnet transaction submitted")
    }
    func testPrepareIsolatedPublicTestWallet() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_BCH_TESTNET_DIR"] else { throw XCTSkip("Public testnet opt-in") }
        let root = URL(fileURLWithPath:directory,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path = root.appendingPathComponent("test-seed.bin")
        if !FileManager.default.fileExists(atPath:path.path) {
            try Data((0..<32).map { _ in UInt8.random(in:0...255) }).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        var seed = try Data(contentsOf:path); defer { seed.resetBytes(in:0..<seed.count) }
        let wallet = try BitcoinCashKeys.wallet(seed:seed)
        let a = try BitcoinKeys.addresses(branch:wallet.branches[0],range:0..<1)[0]
        let address = try BitcoinSendPlan.address(a,on:.chipnet,chain:.bitcoincash)
        try JSONSerialization.data(withJSONObject:["address":address,"scriptHash":a.scriptHash],options:.prettyPrinted)
            .write(to:root.appendingPathComponent("public.json"))
        print("Isolated BCH testnet funding address: " + address)
    }

    /// Fetch/broadcast use Tools/bitcoin-cash-testnet.py, which never reads keys.
    /// Each invocation signs one explicitly opted-in, isolated test-wallet step.
    func testSignPublicChipnetTransfer() throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_BCH_PUBLIC_SIGN_DIR"] else { throw XCTSkip("Public chipnet signing opt-in") }
        let root = URL(fileURLWithPath:directory)
        var testSeed = try Data(contentsOf:root.appendingPathComponent("test-seed.bin"))
        defer { testSeed.resetBytes(in:0..<testSeed.count) }
        let wallet = try BitcoinCashKeys.wallet(seed:testSeed)
        func derived(_ change: UInt32,_ index: UInt32) throws -> BitcoinDerivedAddress {
            try BitcoinKeys.addresses(branch:wallet.branches.first { $0.change == change }!,range:index..<(index+1))[0]
        }
        let publicState = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("public.json"))) as! [String:Any]
        let step = publicState["step"] as? Int ?? 0
        guard (0..<5).contains(step) else { throw XCTSkip("The five public transfers are already complete") }
        let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("utxos.json"))) as! [[String:Any]]
        let coins = try rows.map { row in
            BitcoinSendCoin(accountID:"isolated",txid:row["tx_hash"] as! String,vout:row["tx_pos"] as! Int,value:row["value"] as! Int64,
                address:try derived(UInt32(row["change"] as! Int),UInt32(row["index"] as! Int)),previousTransaction:Data(hex:row["raw"] as! String)!)
        }
        let destination = try derived(UInt32(step%2),UInt32(step+1)), change = try derived(1,UInt32(100+step))
        var recipient = try BitcoinSendPlan.address(destination,on:.chipnet,chain:.bitcoincash)
        if step == 2 { recipient = Base58Check.encode(Data([111])+Data(hex:destination.script)!.dropFirst(3).prefix(20)) }
        if step == 3 { recipient = recipient.uppercased() }
        if step == 4 { recipient = String(recipient.split(separator:":")[1]) }
        let balance = coins.reduce(Int64(0)) { $0 + $1.value }
        let plan = try BitcoinSendPlan.make(coins:coins,recipient:recipient,amount:step == 0 ? balance/2 : balance,
            change:change,ratePerKVByte:1000,network:.chipnet,chain:.bitcoincash)
        let signed = try BitcoinCashSendSigner.sign(plan) { _ in .seed(testSeed,account:0) }
        let addresses = try ([destination] + (plan.changeAmount > 0 ? [change] : [])).map { a -> [String:Any] in
            ["address":try BitcoinSendPlan.address(a,on:.chipnet,chain:.bitcoincash),"scriptHash":a.scriptHash,"change":a.change,"index":a.index]
        }
        try JSONSerialization.data(withJSONObject:["network":"chipnet","raw":signed.raw.hex,"txid":signed.txid,"fee":plan.fee,
            "inputs":plan.coins.count,"step":step,"nextAddresses":addresses],options:.prettyPrinted).write(to:root.appendingPathComponent("signed.json"))
        XCTAssertEqual(try BitcoinTransactions.txid(signed.raw,network:.bitcoincash),signed.txid)
        print("Signed isolated BCH chipnet step \(step); broadcasting is a separate verified operation")
    }

    func testBCHNAcceptsMinesAddressAndFeeMatrix() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BCH_REGTEST"] == "1" else { throw XCTSkip("BCHN isolated regtest opt-in") }
        let rpc = BCHNodeRPC()
        _ = try? rpc.call("createwallet",["oath-bch-send"])
        let mining = try rpc.call("getnewaddress",[]) as! String
        _ = try rpc.call("generatetoaddress",[101,mining])
        let importedKey = Data(repeating:0,count:31)+Data([1])
        let imported = try BitcoinKeys.addresses(branch:BitcoinCashKeys.singleKey(bytes:importedKey,compressed:false).branches[0],range:0..<1)[0]
        let pkh = try address(index:9000), sh20 = Data([0xa9,20])+Data(repeating:7,count:20)+Data([0x87]), sh32 = Data([0xaa,32])+Data(repeating:8,count:32)+Data([0x87])
        let destinations = [try BitcoinSendPlan.address(pkh,on:.regtest,chain:.bitcoincash),
                            Base58Check.encode(Data([111])+Data(hex:pkh.script)!.dropFirst(3).prefix(20)),
                            try CashAddress.encode(script:sh20,prefix:"bchreg"),
                            Base58Check.encode(Data([196])+sh20.dropFirst(2).prefix(20)),
                            try CashAddress.encode(script:sh32,prefix:"bchreg")]
        var receipts: [[String:Any]] = [], counter: UInt32 = 1000
        func send(_ addresses: [BitcoinDerivedAddress], value: Int64, amount: Int64, destination: String) throws {
            let outputs = try Dictionary(uniqueKeysWithValues:addresses.map { (try BitcoinSendPlan.address($0,on:.regtest,chain:.bitcoincash),NSDecimalNumber(decimal:Decimal(value)/100_000_000).stringValue) })
            let hash = try rpc.call("sendmany",["",outputs]) as! String
            _ = try rpc.call("generatetoaddress",[1,mining])
            let raw = Data(hex:try rpc.call("getrawtransaction",[hash]) as! String)!
            let funding = try BitcoinTransactions.details(raw,network:.bitcoincash)
            let coins = addresses.map { a in BitcoinSendCoin(accountID:a == imported ? "import":"hd",txid:hash,
                vout:funding.outputs.firstIndex { $0.script == a.script }!,value:value,address:a,previousTransaction:raw,compressed:a != imported) }
            let p = try plan(coins,amount:amount,recipient:destination,network:.regtest)
            let signed = try BitcoinCashSendSigner.sign(p) { $0 == "import" ? .single(importedKey,compressed:false) : .seed(self.seed,account:0) }
            let check = try rpc.call("testmempoolaccept",[[signed.raw.hex]]) as! [[String:Any]]
            XCTAssertEqual(check[0]["allowed"] as? Bool,true,"BCHN rejected: \(check[0]["reject-reason"] ?? "unknown")")
            guard check[0]["allowed"] as? Bool == true else { throw BitcoinSendError.signing }
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            XCTAssertEqual(try rpc.call("sendrawtransaction",[signed.raw.hex]) as? String,signed.txid)
            _ = try rpc.call("generatetoaddress",[1,mining])
            let fetched = try rpc.call("getrawtransaction",[signed.txid,true]) as! [String:Any]
            XCTAssertEqual(fetched["hex"] as? String,signed.raw.hex); XCTAssertGreaterThan(fetched["confirmations"] as! Int,0)
            receipts.append(["txid":signed.txid,"inputs":p.coins.count,"fee":p.fee,"recipient":p.recipientAmount,"change":p.changeAmount,"size":signed.raw.count])
        }
        for target in destinations {
            for path: UInt32 in [0,1] {
                try send([address(change:path,index:counter)],value:100_000,amount:50_000,destination:target); counter += 1
            }
            try send([imported],value:100_000,amount:50_000,destination:target)
        }
        let mixed = try (0..<254).map { try address(change:UInt32($0%2),index:UInt32(2000+$0)) } + [imported]
        try send(mixed,value:2000,amount:510_000,destination:destinations[0])
        for amount: Int64 in [100_000,99_999,99_700,546] {
            try send([address(index:counter)],value:100_000,amount:amount,destination:destinations[0]); counter += 1
        }
        XCTAssertEqual(receipts.count,20)
        try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/oath-bch-regtest-receipts.json"))
        print("BCHN: 20 transactions accepted, rebroadcast byte-identically and mined; five destination encodings, both HD paths, uncompressed imports, 255 mixed inputs and fee/dust cases")
    }
    func testBCHNRejectsNonForkIDSignatureAndModifiedRecipientAmount() throws {
        guard ProcessInfo.processInfo.environment["OATH_BCH_REGTEST"] == "1" else { throw XCTSkip("BCHN isolated regtest opt-in") }
        let rpc = BCHNodeRPC(), a = try address(index: 20_000)
        _ = try? rpc.call("createwallet", ["oath-bch-send"])
        let mining = try rpc.call("getnewaddress", []) as! String
        _ = try rpc.call("generatetoaddress", [101, mining])
        let hash = try rpc.call("sendtoaddress", [BitcoinSendPlan.address(a, on: .regtest, chain: .bitcoincash), "0.001"]) as! String
        _ = try rpc.call("generatetoaddress", [1, mining])
        let raw = Data(hex: try rpc.call("getrawtransaction", [hash]) as! String)!
        let parent = try BitcoinTransactions.details(raw, network: .bitcoincash)
        let coin = BitcoinSendCoin(accountID: "hd", txid: hash, vout: parent.outputs.firstIndex { $0.script == a.script }!,
                                   value: 100_000, address: a, previousTransaction: raw)
        let p = try plan([coin], amount: 50_000, network: .regtest)
        let signed = try BitcoinCashSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
        // One legacy input: script length at 41, signature push length at 42.
        var wrongFork = signed.raw
        let hashType = 42 + Int(wrongFork[42])
        XCTAssertEqual(wrongFork[hashType], 0x41)
        wrongFork[hashType] = 0x01
        var wrongAmount = signed.raw
        let firstOutput = 42 + Int(wrongAmount[41]) + 4 + 1
        wrongAmount[firstOutput] ^= 1
        for invalid in [wrongFork, wrongAmount] {
            let result = try rpc.call("testmempoolaccept", [[invalid.hex]]) as! [[String: Any]]
            XCTAssertEqual(result[0]["allowed"] as? Bool, false)
            XCTAssertTrue((result[0]["reject-reason"] as? String)?.contains("script") == true)
        }
        let valid = try rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
        XCTAssertEqual(valid[0]["allowed"] as? Bool, true)
    }
}

private struct BCHNodeRPC {
    func call(_ method: String,_ params: [Any]) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath:"/opt/homebrew/bin/docker")
        process.arguments = ["exec","oath-bch-send-regtest","/bchn/bitcoin-cli","-regtest","-datadir=/data","-rpcwallet=oath-bch-send",method] + (try params.map { value in
            if let string = value as? String { return string }
            return String(data:try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed),encoding:.utf8)!
        })
        process.standardOutput = out; process.standardError = err
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"BCHNodeRPC."+method,code:Int(process.terminationStatus)) }
        let text = String(data:data,encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)
        return (try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) ?? text
    }
}
