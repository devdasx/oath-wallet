import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinConnectSignatureProofTests: XCTestCase, BitcoinConnectFixture {
    private func packets(_ type: BitcoinAddressType) throws -> (BitcoinSendCoin, BitcoinConnectPlan, BitcoinConnectPSBT) {
        let funding = try coin(100_000, type: type)
        let original = try plan([funding])
        let other = try plan([funding], request: request(extra: ["amount": "10001"]))
        let signed = try BitcoinConnectSigning.sign(other, source: .seed(seed, account: 0))
        return (funding, original, try BitcoinConnectPSBT(signed.psbt))
    }

    private func checkPeerSignature(_ type: BitcoinAddressType) throws {
        let (funding, original, unrelated) = try packets(type)
        let witness = try XCTUnwrap(unrelated.field(8, input: 0))
        var proposed = try BitcoinConnectPSBT(original.psbt)
        if type == .taproot {
            XCTAssertEqual(witness[0], 1)
            proposed.set(0x13, Data(witness.dropFirst(2)), input: 0)
        } else {
            XCTAssertEqual(witness[0], 2)
            let sig = witness.subdata(in: 2..<(2 + Int(witness[1])))
            proposed.maps[1].append(.init(key: Data([2]) + witness.suffix(33), value: sig))
        }
        let packet = try proposed.encoded
        let req = try request("signPsbt", extra: ["psbt": packet, "signInputs": original.inputs.map {
            ["address": $0.address, "index": $0.index] as [String: Any]
        }])
        let approved = try BitcoinConnectSigning.review(request: req, psbt: packet, inputs: original.inputs,
            addresses: original.reviewedAddresses, previous: [funding.txid: funding.previousTransaction])
        let signed = try BitcoinConnectSigning.sign(approved, source: .seed(seed, account: 0))
        let actual = try XCTUnwrap(BitcoinConnectPSBT(signed.psbt).field(8, input: 0))
        XCTAssertFalse(actual == witness, "Foreign signature was returned for a different transaction")
        try BitcoinConnectSigning.verify(signed, plan: approved)
    }

    func testPeerECDSAPartialCannotReplaceWalletSignature() throws { try checkPeerSignature(.nativeSegwit) }
    func testPeerTaprootPartialCannotReplaceWalletSignature() throws { try checkPeerSignature(.taproot) }

    func testEmptyFinalScriptCannotEnterJournalVerification() throws {
        let (_, approved, _) = try packets(.nativeSegwit)
        var altered = try BitcoinConnectPSBT(approved.psbt)
        altered.set(7, Data(), input: 0)
        let raw = altered.transaction.serialize()
        let unsigned = try BitcoinConnectSigned(psbt: altered.encoded, raw: raw, txid: BitcoinTransactions.txid(raw))
        XCTAssertThrowsError(try BitcoinConnectSigning.verify(unsigned, plan: approved))
    }

    private func checkWrongFinal(_ type: BitcoinAddressType) throws {
        let (funding, original, other) = try packets(type)
        let req = try request("signPsbt", extra: ["psbt": original.psbt, "signInputs": original.inputs.map {
            ["address": $0.address, "index": $0.index] as [String: Any]
        }])
        let approved = try BitcoinConnectSigning.review(request: req, psbt: original.psbt, inputs: original.inputs,
            addresses: original.reviewedAddresses, previous: [funding.txid: funding.previousTransaction])
        let good = try BitcoinConnectSigning.sign(approved, source: .seed(seed, account: 0))
        try BitcoinConnectSigning.verify(good, plan: approved)
        var altered = try BitcoinConnectPSBT(good.psbt)
        for field: UInt8 in [7, 8] {
            if let value = other.field(field, input: 0) { altered.set(field, value, input: 0) }
        }
        let bad = try BitcoinConnectSigned(psbt: altered.encoded, raw: nil, txid: nil)
        XCTAssertThrowsError(try BitcoinConnectSigning.verify(bad, plan: approved))
    }

    func testForeignFinalLegacyProofRejected() throws { try checkWrongFinal(.legacy) }
    func testForeignFinalNestedProofRejected() throws { try checkWrongFinal(.nestedSegwit) }
    func testForeignFinalNativeProofRejected() throws { try checkWrongFinal(.nativeSegwit) }
    func testForeignFinalTaprootProofRejected() throws { try checkWrongFinal(.taproot) }

    func testValidRequestedInputsRemainVerifiable() throws {
        for type in BitcoinAddressType.allCases {
            let approved = try plan([coin(100_000, type: type)])
            let signed = try BitcoinConnectSigning.sign(approved, source: .seed(seed, account: 0))
            try BitcoinConnectSigning.verify(signed, plan: approved)
        }
    }
}
