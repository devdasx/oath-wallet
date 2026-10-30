import XCTest
import CryptoKit
@testable import OathAnkr

final class SuiSendTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func testOfficialSDKBytesSignatureAndDigest() throws {
        let url = Bundle.module.url(forResource:"sdk-vector",withExtension:"json",subdirectory:"Fixtures/SuiSend")!
        let expected = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
        let sender = try SuiSendCrypto.address(privateKey:key)
        XCTAssertEqual(sender,expected["address"])
        let funds = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let plan = try SuiSendPlan.make(network:.testnet,sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000,
            native:funds,asset:funds,gasPrice:1000,gasBudget:5_000_000,epoch:1252,nonce:42)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        XCTAssertEqual(signed.bytes.base64EncodedString(),expected["bytes"])
        XCTAssertEqual(SuiSendCrypto.hash(Data([0,0,0])+signed.bytes).map { String(format:"%02x",$0) }.joined(),expected["intentHash"])
        let official = SuiSignedSend(bytes:signed.bytes,signature:Data(base64Encoded:expected["signature"]!)!,digest:signed.digest)
        XCTAssertNoThrow(try SuiSendCrypto.verify(official,sender:sender))
        XCTAssertEqual(signed.digest,expected["digest"])
        XCTAssertNoThrow(try SuiSendCrypto.verify(signed,sender:sender))
        XCTAssertThrowsError(try SuiSendCrypto.verify(signed,sender:try SuiIdentity.address("0xabc")))
    }
    func testBlake2bKnownAnswersAndBase58RoundTrip() throws {
        XCTAssertEqual(SuiSendCrypto.hash(Data()).map { String(format:"%02x",$0) }.joined(),"0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
        for size in [0,1,31,32] {
            let data = Data(repeating:0,count:size)+Data([1,2,3,254,255])
            XCTAssertEqual(try SuiSendCrypto.unbase58(SuiSendCrypto.base58(data)),data)
        }
    }
    func testNativeMaxReservesGasAndTokenMaxDoesNotDeductTokenFee() throws {
        let sender = try SuiSendCrypto.address(privateKey:key)
        let native = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let token = SuiSendFunds(coins:[],addressBalance:UInt64.max)
        let max = try SuiSendPlan.make(network:.testnet,sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000_000,
            native:native,asset:native,gasPrice:1000,gasBudget:5_000_000,estimatedFee:1_000_000,epoch:1252)
        XCTAssertEqual(max.amount,995_000_000); XCTAssertEqual(max.remaining,4_000_000)
        let plan = try SuiSendPlan.make(network:.testnet,sender:sender,recipient:"0xabc",reference:"0x3::coin::TOKEN",amount:UInt64.max,
            native:native,asset:token,gasPrice:1000,gasBudget:5_000_000,epoch:1252)
        XCTAssertEqual(plan.amount,UInt64.max); XCTAssertEqual(plan.withdrawal,UInt64.max)
        XCTAssertNoThrow(try plan.transactionBytes())
        XCTAssertThrowsError(try plan.validate(now:plan.createdAt.addingTimeInterval(121)))
        XCTAssertThrowsError(try SuiSendCrypto.sign(plan,privateKey:Data(repeating:8,count:32)))
    }
    func testNoGasAndOverflowAndDuplicateInputsFailClosed() throws {
        let funds = SuiSendFunds(coins:[],addressBalance:1)
        XCTAssertThrowsError(try SuiSendPlan.make(network:.testnet,sender:"0x1",recipient:"0x2",reference:"native",amount:1,native:funds,asset:funds,gasPrice:1,gasBudget:5,epoch:1))
        let coin = SuiSendCoin(id:try SuiIdentity.address("0x4"),digest:SuiSendCrypto.base58(Data(repeating:1,count:32)),version:1,balance:10_000_000)
        let dup = SuiSendFunds(coins:[coin,coin],addressBalance:0)
        XCTAssertThrowsError(try SuiSendPlan.make(network:.testnet,sender:"0x1",recipient:"0x2",reference:"native",amount:1,native:dup,asset:dup,gasPrice:1,gasBudget:5,epoch:1))
        XCTAssertThrowsError(try SuiSendFunds(coins:[coin],addressBalance:UInt64.max).total)
    }
    /// Opt-in, public TESTNET only. Uses the exact production builder/signer/
    /// transport. Never loads application wallets or touches mainnet funds.
    func testLiveTestnetNativeTransfer() async throws {
        guard let file = ProcessInfo.processInfo.environment["OATH_SUI_TESTNET_KEY_FILE"] else { throw XCTSkip("Explicit funded testnet key required") }
        var secret = try Data(contentsOf:URL(fileURLWithPath:file)); defer { secret.resetBytes(in:0..<secret.count) }
        let sender = try SuiSendCrypto.address(privateKey:secret), recipient = try SuiSendCrypto.address(privateKey:Curve25519.Signing.PrivateKey().rawRepresentation)
        let client = try SuiSendClient(network:.testnet)
        let before = try await client.funds(owner:recipient,reference:"native").total
        let plan = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:1_000_000)
        XCTAssertGreaterThan(plan.gasBudget,0); XCTAssertLessThanOrEqual(plan.estimatedFee,plan.gasBudget)
        let signed = try SuiSendCrypto.sign(plan,privateKey:secret)
        let receipt = try await client.submit(signed,sender:sender)
        XCTAssertEqual(receipt.outcome,.confirmed)
        var status = try await client.status(digest:signed.digest)
        for _ in 0..<15 where status.outcome == .unknown {
            try await Task.sleep(for:.seconds(1))
            status = try await client.status(digest:signed.digest)
        }
        XCTAssertEqual(status.outcome,.confirmed)
        var after: UInt64 = 0
        for _ in 0..<10 {
            after = try await client.funds(owner:recipient,reference:"native").total
            if after == before+plan.amount { break }
            try await Task.sleep(for:.seconds(1))
        }
        XCTAssertEqual(after,before+plan.amount)
        let retried = try await client.submit(signed,sender:sender)
        XCTAssertEqual(retried.outcome,.confirmed)
        let afterRetry = try await client.funds(owner:recipient,reference:"native").total
        XCTAssertEqual(afterRetry,after,"Exact-byte retry must not double spend")
        print("SUI_TESTNET_NATIVE_CONFIRMED digest=\(signed.digest) amount=\(plan.amount) budget=\(plan.gasBudget) fee=\(receipt.fee ?? 0)")
    }
    func testLiveTestnetObjectGasTokenReturnAndNativeMaximum() async throws {
        guard let file = ProcessInfo.processInfo.environment["OATH_SUI_TESTNET_KEY_FILE"],
              let reference = ProcessInfo.processInfo.environment["OATH_SUI_TESTNET_TOKEN"] else { throw XCTSkip("Explicit testnet fixture required") }
        var secret = try Data(contentsOf:URL(fileURLWithPath:file)); defer { secret.resetBytes(in:0..<secret.count) }
        let secondaryKey = Curve25519.Signing.PrivateKey().rawRepresentation
        let primary = try SuiSendCrypto.address(privateKey:secret), secondary = try SuiSendCrypto.address(privateKey:secondaryKey)
        let client = try SuiSendClient(network:.testnet)
        // Fund the object-only test wallet with the same production send code.
        let funding = try await client.quote(sender:primary,recipient:secondary,reference:"native",amount:50_000_000)
        let funded = try await client.submit(SuiSendCrypto.sign(funding,privateKey:secret),sender:primary)
        XCTAssertEqual(funded.outcome,.confirmed)
        try await Task.sleep(for:.seconds(2))
        let objectFunds = try await client.funds(owner:secondary,reference:"native")
        XCTAssertEqual(objectFunds.addressBalance,0); XCTAssertFalse(objectFunds.coins.isEmpty)
        for maximum in [false,true] {
            let before = try await client.funds(owner:secondary,reference:reference).total
            let available = try await client.funds(owner:primary,reference:reference).total
            let amount: UInt64 = maximum ? available : 1_234_567
            let plan = try await client.quote(sender:primary,recipient:secondary,reference:reference,amount:amount)
            XCTAssertEqual(plan.amount,amount); XCTAssertEqual(plan.deductedFromAmount,0)
            let signed = try SuiSendCrypto.sign(plan,privateKey:secret)
            let receipt = try await client.submit(signed,sender:primary)
            XCTAssertEqual(receipt.outcome,.confirmed)
            var after: UInt64 = 0
            for _ in 0..<15 {
                after = try await client.funds(owner:secondary,reference:reference).total
                if after == before+amount { break }
                try await Task.sleep(for:.seconds(1))
            }
            XCTAssertEqual(after,before+amount)
            print("SUI_TESTNET_TOKEN_CONFIRMED digest=\(signed.digest) amount=\(amount) max=\(maximum) fee=\(receipt.fee ?? 0)")
        }
        for maximum in [false,true] {
            let available = try await client.funds(owner:secondary,reference:reference).total
            let amount: UInt64 = maximum ? available : 12345
            let before = try await client.funds(owner:primary,reference:reference).total
            let plan = try await client.quote(sender:secondary,recipient:primary,reference:reference,amount:amount)
            XCTAssertFalse(plan.gasCoins.isEmpty); XCTAssertEqual(plan.amount,amount)
            let signed = try SuiSendCrypto.sign(plan,privateKey:secondaryKey)
            let receipt = try await client.submit(signed,sender:secondary)
            XCTAssertEqual(receipt.outcome,.confirmed)
            var after: UInt64 = 0
            for _ in 0..<15 {
                after = try await client.funds(owner:primary,reference:reference).total
                if after == before+amount { break }
                try await Task.sleep(for:.seconds(1))
            }
            XCTAssertEqual(after,before+amount)
            print("SUI_TESTNET_OBJECT_GAS_TOKEN_CONFIRMED digest=\(signed.digest) max=\(maximum) amount=\(amount) fee=\(receipt.fee ?? 0)")
        }
        let balance = try await client.funds(owner:secondary,reference:"native").total
        let maximum = try await client.quote(sender:secondary,recipient:primary,reference:"native",amount:balance)
        XCTAssertEqual(maximum.amount,balance-maximum.gasBudget)
        let signed = try SuiSendCrypto.sign(maximum,privateKey:secondaryKey)
        let receipt = try await client.submit(signed,sender:secondary)
        XCTAssertEqual(receipt.outcome,.confirmed)
        var remaining: UInt64 = 0
        for _ in 0..<15 {
            remaining = try await client.funds(owner:secondary,reference:"native").total
            if remaining == balance-maximum.amount-(receipt.fee ?? 0)+receipt.gasRefund { break }
            try await Task.sleep(for:.seconds(1))
        }
        XCTAssertEqual(remaining,balance-maximum.amount-(receipt.fee ?? 0)+receipt.gasRefund)
        print("SUI_TESTNET_NATIVE_MAX_CONFIRMED digest=\(signed.digest) amount=\(maximum.amount) fee=\(receipt.fee ?? 0)")
    }

    /// Public mainnet simulation only: no private key, signing or broadcast.
    func testLiveMainnetPreparationWithConfiguredProvider() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SUI_KEY"] else { throw XCTSkip("Explicit public mainnet reads required") }
        let client = try SuiSendClient(network:.mainnet,apiKey:key)
        let plan = try await client.quote(sender:"0x42960e77d87a60d0a0599757beb320147510933c5e63a6ccfec3fdd54aa796fc",recipient:"0xabc",reference:"native",amount:1_000_000)
        XCTAssertEqual(plan.network,.mainnet); XCTAssertEqual(plan.amount,1_000_000)
        XCTAssertGreaterThan(plan.gasBudget,0); XCTAssertLessThanOrEqual(plan.estimatedFee,plan.gasBudget)
        print("SUI_MAINNET_SIMULATION_PASSED fee=\(plan.estimatedFee) budget=\(plan.gasBudget) gasPrice=\(plan.gasPrice); no signature or broadcast")
    }

}
