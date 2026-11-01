import Foundation
import XCTest
@testable import OathBitcoin

final class ConnectPlanSizeTests: XCTestCase {
    // All eight inputs reference different outputs of the same synthetic parent.
    private func review(parentOutputs: Int) throws -> BitcoinConnectPlan {
        let seed = Data(0..<32)
        let branch = try XCTUnwrap(BitcoinKeys.wallet(seed: seed).branches.first { $0.type == .nativeSegwit && $0.change == 0 })
        let account = try XCTUnwrap(BitcoinKeys.addresses(branch: branch, range: 0..<1).first)
        let destination = try XCTUnwrap(BitcoinKeys.addresses(branch: branch, range: 2..<3).first)
        let inputScript = try XCTUnwrap(Data(hex: account.script))
        let chain = BitcoinConnectNetwork.signet
        let address = try chain.address(mainnetAddress: account.address)
        var parent = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 2, count: 32)
        parent += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + BitcoinWire.compact(UInt64(parentOutputs))
        for _ in 0..<parentOutputs { parent += BitcoinWire.little(UInt64(12_500)) + BitcoinWire.vector(inputScript) }
        parent += BitcoinWire.little(UInt32(0))
        let hash = try BitcoinTransactions.txid(parent)
        var tx = BitcoinWire.little(UInt32(2)) + Data([8])
        let prior = Data(try XCTUnwrap(Data(hex: hash)).reversed())
        for index in 0..<8 { tx += prior + BitcoinWire.little(UInt32(index)) + Data([0]) + BitcoinWire.little(UInt32.max) }
        tx += Data([1]) + BitcoinWire.little(UInt64(99_000)) + BitcoinWire.vector(try XCTUnwrap(Data(hex: destination.script)))
        tx += BitcoinWire.little(UInt32(0))
        let packet = Data([0x70,0x73,0x62,0x74,0xff]) + BitcoinWire.pair(0,tx) + Data(repeating:0,count:10)
        let base64 = packet.base64EncodedString()
        let params = try JSONSerialization.data(withJSONObject: ["account":address,"psbt":base64,"signInputs":[["address":address,"index":0]]])
        let request = try BitcoinConnectRequest(method:"signPsbt",chain:chain.chain,account:address,params:params)
        return try BitcoinConnectSigning.review(request:request,psbt:base64,inputs:try XCTUnwrap(request.signInputs),addresses:[account],previous:[hash:parent])
    }

    func testCompactRequestCannotReturnOversizedUnusableReviewPlan() throws {
        do {
            let plan = try review(parentOutputs: 2_050)
            let bytes = try XCTUnwrap(Data(base64Encoded: plan.psbt))
            XCTFail("Review returned a packet of \(bytes.count) bytes beyond the signing limit")
            XCTAssertNoThrow(try BitcoinConnectSigning.validate(plan), "A returned plan must pass revalidation")
        } catch {
            XCTAssertEqual(error as? BitcoinConnectError, .tooLarge)
        }
    }
    func testSmallerRequestStillValidates() throws {
        let plan = try review(parentOutputs: 1_800)
        try BitcoinConnectSigning.validate(plan)
        XCTAssertEqual(plan.fee, 1_000)
    }
}
