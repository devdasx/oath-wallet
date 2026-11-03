import XCTest
@testable import OathAnkr

final class TransactionBufferTests: XCTestCase {
    func sliced(_ data: Data, prefix: Int = 17) -> Data {
        let slice = (Data(repeating: 0xaa, count: prefix) + data).dropFirst(prefix)
        XCTAssertEqual(slice.startIndex, prefix)
        return slice
    }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func stellarPlan(_ resources: Data) throws -> StellarSendPlan {
        let seed = Data(repeating: 11, count: 32)
        let sender = try StellarSendCrypto.address(privateKey: seed)
        let recipient = try StellarSendCrypto.address(privateKey: Data(repeating: 12, count: 32))
        let contract = StellarIdentity.encode(Array(repeating: 42, count: 32), version: 16)
        return StellarSendPlan(network: .testnet, kind: .contract, sender: sender, recipient: recipient,
            reference: contract, decimals: 6, requestedAmount: "12345", amount: "12345",
            assetBalance: "1000000000", nativeBalance: 1_000_000_000, reserve: 10_000_000,
            fee: 1120, sequence: 42, firstLedger: 1000, lastLedger: 1025, maxTime: 1_700_000_120,
            sorobanData: resources,
            authorization: [try StellarSendXDR.sourceAuthorization(reference: contract, sender: sender, recipient: recipient, amount: "12345")],
            createdAt: date)
    }
    // Empty read/write footprint, three resource counters, fee 1000 stroops.
    var resources: Data { Data(repeating: 0, count: 24) + Data([0,0,0,0,0,0,3,232]) }
    func testStellarPublicPlanControl() throws {
        let plan = try stellarPlan(resources)
        try plan.validate(now: date)
        let signed = try StellarSendCrypto.sign(plan, privateKey: Data(repeating: 11, count: 32), now: date)
        try StellarSendCrypto.verify(signed, plan: plan)
        XCTAssertEqual(try StellarSendXDR.resourceFee(resources), 1000)
    }
    func testStellarPublicPlanSlice() throws {
        let control = try StellarSendXDR.transaction(stellarPlan(resources))
        for prefix in [1,2,17,128] {
            let plan = try stellarPlan(sliced(resources, prefix: prefix))
            try plan.validate(now: date)
            XCTAssertEqual(try StellarSendXDR.transaction(plan), control)
            let signed = try StellarSendCrypto.sign(plan, privateKey: Data(repeating: 11, count: 32), now: date)
            try StellarSendCrypto.verify(signed, plan: plan)
        }
    }
    func testStellarTruncatedResourcesSlice() throws {
        for length in 0..<resources.count {
            XCTAssertThrowsError(try StellarSendXDR.resourceFee(sliced(Data(resources.prefix(length)))))
        }
    }
    func testStellarVectorAndMapSlices() throws {
        for type: UInt32 in [16,17] {
            let bytes = StellarSendXDR.u32(type) + StellarSendXDR.u32(1) + StellarSendXDR.u32(1)
                + Data(repeating: 0, count: 0) + StellarSendXDR.u32(1)
                + (type == 17 ? StellarSendXDR.u32(1) : Data())
            var control = StellarSendXDR.Reader(data: bytes)
            try control.value()
            var reader = StellarSendXDR.Reader(data: sliced(bytes))
            try reader.value()
            XCTAssertEqual(reader.offset, bytes.count)
            XCTAssertEqual(reader.offset, control.offset)
        }
    }
    let compactValues = ["0","63","64","16383","16384","1073741823","1073741824","18446744073709551616","340282366920938463463374607431768211455"]
    func testScaleCompactControl() throws {
        for value in compactValues {
            let bytes = try PolkadotScale.compact(value)
            var reader = PolkadotScale(bytes)
            XCTAssertEqual(try reader.compact(), value)
            XCTAssertEqual(reader.offset, bytes.count)
        }
    }
    func testScaleCompactSlice() throws {
        for value in compactValues {
            let bytes = try PolkadotScale.compact(value)
            for prefix in [1,2,17,128] {
                var reader = PolkadotScale(sliced(bytes, prefix: prefix))
                XCTAssertEqual(try reader.compact(), value)
                XCTAssertEqual(reader.offset, bytes.count)
            }
        }
    }
    func testScaleTruncatedSlice() throws {
        for value in compactValues {
            let bytes = try PolkadotScale.compact(value)
            for length in 0..<bytes.count {
                var reader = PolkadotScale(sliced(Data(bytes.prefix(length))))
                XCTAssertThrowsError(try reader.compact())
            }
        }
    }
    // Minimal v14 container: empty types/pallets, extrinsic type 0, version 4,
    // empty signed extensions, runtime type 0. It cannot authorize a send.
    var metadata: Data { Data("meta".utf8) + Data([14,0,0,0,4,0,0]) }
    func testScaleMetadataControl() throws {
        let runtime = try PolkadotRuntime(metadata)
        XCTAssertTrue(runtime.types.isEmpty)
        XCTAssertTrue(runtime.pallets.isEmpty)
        XCTAssertThrowsError(try runtime.call(pallet: "Balances", name: "transfer_keep_alive"))
    }
    func testScaleMetadataSlice() throws {
        let control = try PolkadotRuntime(metadata)
        for prefix in [1,2,17,128] {
            let runtime = try PolkadotRuntime(sliced(metadata, prefix: prefix))
            XCTAssertEqual(runtime.fingerprint, control.fingerprint)
            XCTAssertTrue(runtime.types.isEmpty)
            XCTAssertThrowsError(try runtime.call(pallet: "Balances", name: "transfer_keep_alive"))
        }
    }
}
