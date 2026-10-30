import XCTest
@testable import OathDatabase

final class EVMHistoryPersistenceTests: XCTestCase {
    func testSparseReceiptMergePreservesOnlyUnchangedInclusion() {
        let old = TransactionRecord(id: "tx", networkID: "evm", hash: "0xabc", state: "confirmed",
                                    blockHeight: 10, blockHash: "block-a", timestamp: 1,
                                    feeAtomic: "123", updatedAt: 1)
        var sparse = old
        sparse.blockHash = nil; sparse.feeAtomic = nil; sparse.updatedAt = 2
        let merged = sparse.retainingEVMReceipt(from: old)
        XCTAssertEqual(merged.blockHash, old.blockHash)
        XCTAssertEqual(merged.feeAtomic, old.feeAtomic)
        XCTAssertEqual(merged.updatedAt, 2)

        for change in ["height", "missing-height", "state", "hash", "network", "id"] {
            var changed = sparse
            switch change {
            case "height": changed.blockHeight = 11
            case "missing-height": changed.blockHeight = nil
            case "state": changed.state = "pending"
            case "hash": changed.hash = "0xdef"
            case "network": changed.networkID = "other"
            default: changed.id = "other"
            }
            let result = changed.retainingEVMReceipt(from: old)
            XCTAssertNil(result.blockHash, change)
            XCTAssertNil(result.feeAtomic, change)
        }

        sparse.blockHash = "block-b"
        let reorganized = sparse.retainingEVMReceipt(from: old)
        XCTAssertEqual(reorganized.blockHash, "block-b")
        XCTAssertNil(reorganized.feeAtomic)
        sparse.feeAtomic = "456"
        XCTAssertEqual(sparse.retainingEVMReceipt(from: old).feeAtomic, "456")
        XCTAssertEqual(sparse.retainingEVMReceipt(from: nil), sparse)
    }
}
