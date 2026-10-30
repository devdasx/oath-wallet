import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinConnectTests: XCTestCase {
    // Published, deterministic test material. Never used on mainnet.
    let seed = Data(0..<32)
    func address(_ type: BitcoinAddressType = .nativeSegwit, change: UInt32 = 0, index: UInt32 = 0) throws -> BitcoinDerivedAddress {
        let branch = try BitcoinKeys.wallet(seed: seed).branches.first { $0.type == type && $0.change == change }!
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
    }
    func coin(_ value: Int64, type: BitcoinAddressType = .nativeSegwit, index: UInt32 = 0,
              change: UInt32 = 0, compressed: Bool = true) throws -> BitcoinSendCoin {
        let a = try compressed ? address(type, change: change, index: index) : BitcoinKeys.addresses(
            branch: BitcoinKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false).branches[0], range: 0..<1)[0]
        // Synthetic funding transaction for pure signing tests; Core tests below
        // use real mined/funded transactions instead.
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(index) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(value)) + BitcoinWire.vector(Data(hex: a.script)!)
        raw += BitcoinWire.little(UInt32(0))
        return .init(accountID: "test", txid: try BitcoinTransactions.txid(raw), vout: 0, value: value,
                     address: a, previousTransaction: raw, compressed: compressed)
    }

    func request(_ method: String = "sendTransfer", network: BitcoinConnectNetwork = .signet, extra: [String:Any] = [:]) throws -> BitcoinConnectRequest {
        let account = try network.address(mainnetAddress: address().address)
        var params: [String:Any] = ["account":account]
        if method == "sendTransfer" {
            params["recipientAddress"] = try network.address(mainnetAddress: address(index:12).address)
            params["amount"] = "10000"
        }
        params.merge(extra) { _, new in new }
        return try .init(method:method,chain:network.chain,account:account,params:JSONSerialization.data(withJSONObject:params))
    }
    func plan(_ coins: [BitcoinSendCoin], request: BitcoinConnectRequest? = nil) throws -> BitcoinConnectPlan {
        let request = try request ?? self.request()
        let change = try address(change:1)
        let (psbt,inputs) = try BitcoinConnectClient.transfer(request,coins:coins.map { .init(txid:$0.txid,vout:UInt32($0.vout),value:UInt64($0.value),address:$0.address) },change:change,rate:2)
        return try BitcoinConnectSigning.review(request:request,psbt:psbt,inputs:inputs,addresses:coins.map(\.address)+[change],previous:Dictionary(uniqueKeysWithValues:coins.map { ($0.txid,$0.previousTransaction) }))
    }
    func testAllAddressTypesAndNetworks() throws {
        for network in BitcoinConnectNetwork.allCases {
            for type in BitcoinAddressType.allCases {
                for change: UInt32 in [0,1] {
                    let p = try plan([coin(20000,type:type,change:change)],request:request(network:network))
                    let signed = try BitcoinConnectSigning.sign(p,source:.seed(seed,account:0))
                    try BitcoinConnectSigning.verify(signed,plan:p)
                    XCTAssertEqual(signed.txid,try BitcoinTransactions.txid(signed.raw!))
                    XCTAssertEqual(p.outputs[0].value,10000)
                    XCTAssertEqual(p.outputs.reduce(0) { $0+$1.value }+p.fee,20000)
                }
            }
        }
    }
    func testMalformedAndWrongNetworkRequests() throws {
        for amount in ["-1","0","1.2","1e4","2100000000000001"] { XCTAssertThrowsError(try request(extra:["amount":amount])) }
        XCTAssertThrowsError(try request(extra:["recipientAddress":address().address]))
        XCTAssertThrowsError(try request(extra:["memo":"zz"]))
        XCTAssertThrowsError(try request(extra:["memo":String(repeating:"ab",count:81)]))
        XCTAssertThrowsError(try request(extra:["account":"other"]))
    }
    func testUncompressedLegacyImportHasEnoughFeeSpace() throws {
        let p = try plan([coin(20000,type:.legacy,compressed:false)])
        let key = Data(repeating:0,count:31) + Data([1])
        let signed = try BitcoinConnectSigning.sign(p,source:.single(key,compressed:false))
        try BitcoinConnectSigning.verify(signed,plan:p)
        XCTAssertGreaterThanOrEqual(p.fee,UInt64(signed.raw!.count) * 2)
    }
    func testDecodedRequestsRetainParameterBounds() throws {
        let original = try request()
        for (field,value) in [("memo",String(repeating:"ab",count:300)),("amount",String(UInt64.max))] {
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any]
            json[field] = value
            let decoded = try JSONDecoder().decode(BitcoinConnectRequest.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertThrowsError(try BitcoinConnectClient.transfer(decoded,coins:[],change:address(change:1),rate:1))
        }
    }
    func testAccountAuthorizationAcceptsStoredAndNegotiatedEncodings() throws {
        for type in BitcoinAddressType.allCases {
            let stored = try address(type).address, other = try address(type,index:1).address
            for network in BitcoinConnectNetwork.allCases {
                let negotiated = try network.address(mainnetAddress:stored)
                XCTAssertTrue(network.matchesAccount(stored,negotiated))
                XCTAssertTrue(network.matchesAccount(negotiated,negotiated))
                XCTAssertFalse(network.matchesAccount(other,negotiated))
                if network != .mainnet {
                    XCTAssertFalse(BitcoinConnectNetwork.mainnet.matchesAccount(stored,negotiated))
                }
            }
        }
    }
    func testParentsSighashesAndFinalizedInputsAreValidated() throws {
        let c = try coin(20000), transfer = try plan([c])
        let own = try BitcoinConnectNetwork.signet.address(mainnetAddress:c.address.address)
        func review(_ value: BitcoinConnectPSBT, selected: Int = 0) throws {
            let req = try request("signPsbt",extra:["psbt":value.encoded,"signInputs":[["address":own,"index":selected]]])
            _ = try BitcoinConnectSigning.review(request:req,psbt:value.encoded,inputs:req.signInputs!,addresses:transfer.reviewedAddresses,previous:[c.txid:c.previousTransaction])
        }
        var parsed = try BitcoinConnectPSBT(transfer.psbt)
        parsed.set(1,BitcoinWire.little(UInt64(90000)) + BitcoinWire.vector(Data(hex:c.address.script)!),input:0)
        XCTAssertThrowsError(try review(parsed))
        parsed = try BitcoinConnectPSBT(transfer.psbt); parsed.set(3,BitcoinWire.little(UInt32(0x81)),input:0)
        XCTAssertThrowsError(try review(parsed))
        parsed = try BitcoinConnectPSBT(transfer.psbt); parsed.set(7,Data([0]),input:0)
        XCTAssertThrowsError(try review(parsed))
        parsed = try BitcoinConnectPSBT(transfer.psbt)
        XCTAssertThrowsError(try review(parsed,selected:1))
        XCTAssertThrowsError(try BitcoinConnectSigning.review(request:transfer.request,psbt:transfer.psbt,inputs:transfer.inputs,
            addresses:transfer.reviewedAddresses,previous:[c.txid:Data([0])]))
    }
    func testMixedInputPSBTPreservesUnrequestedInputs() throws {
        let first = try coin(7000,index:0), foreign = try coin(7000,index:1)
        let transfer = try plan([first,foreign])
        let input = transfer.inputs.first { $0.address == (try? BitcoinConnectNetwork.signet.address(mainnetAddress:first.address.address)) }!
        let req = try request("signPsbt",extra:["psbt":transfer.psbt,"signInputs":[["address":input.address,"index":input.index]]])
        let reviewed = try BitcoinConnectSigning.review(request:req,psbt:transfer.psbt,inputs:req.signInputs!,addresses:[first.address,try address(change:1)],
            previous:[first.txid:first.previousTransaction,foreign.txid:foreign.previousTransaction])
        let signed = try BitcoinConnectSigning.sign(reviewed,source:.seed(seed,account:0))
        let original = try BitcoinConnectPSBT(reviewed.psbt), result = try BitcoinConnectPSBT(signed.psbt)
        let unrequested = input.index == 0 ? 1 : 0
        XCTAssertEqual(original.maps[unrequested + 1],result.maps[unrequested + 1])
        try BitcoinConnectSigning.verify(signed,plan:reviewed)
        XCTAssertNil(result.field(7,input:unrequested)); XCTAssertNil(result.field(8,input:unrequested))
    }
    func testMemoMustMatchReviewedRequestAndUnsignedPacketsCannotPassVerification() throws {
        let memo = Data("Oath 🌍".utf8).map { String(format:"%02x",$0) }.joined()
        let p = try plan([coin(20000)],request:request(extra:["memo":memo]))
        let signed = try BitcoinConnectSigning.sign(p,source:.seed(seed,account:0))
        try BitcoinConnectSigning.verify(signed,plan:p)
        XCTAssertEqual(p.outputs.last?.dataOutput?.message,"Oath 🌍")
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        var req = json["request"] as! [String:Any]; req["memo"] = "6162"; json["request"] = req
        let edited = try JSONDecoder().decode(BitcoinConnectPlan.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertThrowsError(try BitcoinConnectSigning.sign(edited,source:.seed(seed,account:0)))
        XCTAssertThrowsError(try BitcoinConnectSigning.verify(.init(psbt:p.psbt,raw:signed.raw,txid:signed.txid),plan:p))
    }
    func testTamperedPlanAndWrongKeyRejected() throws {
        let p = try plan([coin(20000)])
        for key in ["fee","debit"] {
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
            json[key] = 1
            let edited = try JSONDecoder().decode(BitcoinConnectPlan.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertThrowsError(try BitcoinConnectSigning.sign(edited,source:.seed(seed,account:0)))
        }
        XCTAssertThrowsError(try BitcoinConnectSigning.sign(p,source:.seed(Data(repeating:9,count:32),account:0)))
    }
    func testForeignChangeAndInsufficientFundsRejected() throws {
        XCTAssertThrowsError(try plan([coin(20000)],request:request(extra:["changeAddress":BitcoinConnectNetwork.signet.address(mainnetAddress:address(index:42).address)])))
        XCTAssertThrowsError(try plan([coin(10000)]))
    }
    func testSignOnlyPSBTPreservesTransaction() throws {
        let transfer = try plan([coin(20000)])
        let req = try request("signPsbt",extra:["psbt":transfer.psbt,"signInputs":transfer.inputs.map { ["address":$0.address,"index":$0.index] as [String:Any] }])
        let c = try coin(20000)
        let p = try BitcoinConnectSigning.review(request:req,psbt:transfer.psbt,inputs:req.signInputs!,addresses:transfer.reviewedAddresses,previous:[c.txid:c.previousTransaction])
        let signed = try BitcoinConnectSigning.sign(p,source:.seed(seed,account:0))
        XCTAssertNil(signed.raw); XCTAssertNil(signed.txid)
        try BitcoinConnectSigning.verify(signed,plan:p)
    }
    func testMessageSignatures() throws {
        for type in BitcoinAddressType.allCases {
            let a = try address(type)
            for proto in ["ecdsa","bip322"] where proto == "ecdsa" ? type != .taproot : [.nativeSegwit,.taproot].contains(type) {
                let req = try request("signMessage",extra:["message":"Oath Bitcoin test","address":BitcoinConnectNetwork.signet.address(mainnetAddress:a.address),"protocol":proto])
                let sig = try BitcoinConnectSigning.message(req,address:a,source:.seed(seed,account:0))
                XCTAssertFalse(sig.signature.isEmpty); XCTAssertEqual(sig.messageHash.count,64)
            }
        }
    }
}
