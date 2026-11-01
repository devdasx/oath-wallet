import XCTest
@testable import OathAnkr

/// Synthetic provider observations; checksum vector from EIP-55. No network.
final class ThorchainSwapDestinationTests: XCTestCase {
    private let checksum = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    private let txHash = String(repeating: "AB", count: 32)
    private let outboundHash = String(repeating: "CD", count: 32)

    private func progress(chain: String, asset: String, requested: String, observed: String,
                          observedChain: String? = nil, observedAsset: String? = nil,
                          observedMemo: String? = nil) throws -> ThorchainSwapProgress {
        let fixture = ThorchainSwapProgressTests()
        var root = try fixture.fixture(swapped: true, signed: true)
        root = fixture.with(root, "tx", fixture.with(root["tx"], "memo", .string("=:\(asset):\(requested):100/1/1")))
        let out: SolanaJSON = .object([
            "id": .string(outboundHash), "chain": .string(observedChain ?? chain),
            "to_address": .string(observed), "memo": .string(observedMemo ?? "OUT:" + txHash),
            "coins": .array([.object(["asset": .string(observedAsset ?? asset), "amount": .string("120")])])
        ])
        root = fixture.with(root, "out_txs", .array([out]))
        return try XCTUnwrap(ThorchainSwapProgress.decode(root, hash: txHash))
    }

    func testPolygonNativeAndTokenPayoutsMatchChecksumVariants() throws {
        for asset in ["POL.POL", "POL.USDC-0X" + String(repeating: "12", count: 20)] {
            for (requested, observed) in [(checksum, checksum.lowercased()), (checksum.lowercased(), checksum)] {
                let result = try progress(chain: "POL", asset: asset, requested: requested, observed: observed)
                XCTAssertEqual(result.outboundHash, outboundHash,
                    "Polygon checksum variants must identify the same payout destination")
            }
        }
    }

    func testOtherSupportedEVMChainsPreserveCaseInsensitiveMatching() throws {
        let assets = ["ETH": "ETH.ETH", "BSC": "BSC.BNB", "AVAX": "AVAX.AVAX", "BASE": "BASE.ETH"]
        for (chain, asset) in assets.sorted(by: { $0.key < $1.key }) {
            for (requested, observed) in [(checksum, checksum.lowercased()), (checksum.lowercased(), checksum)] {
                let result = try progress(chain: chain, asset: asset, requested: requested, observed: observed)
                XCTAssertEqual(result.outboundHash, outboundHash)
                XCTAssertTrue(result.isFinished)
            }
        }
    }

    func testMatchingNeverIgnoresDifferentAddressesChainsAssetsOrInboundIDs() throws {
        let other = "0x" + String(repeating: "33", count: 20)
        for chain in ThorchainSwapAsset.evmChains.values.sorted() {
            let asset = chain + ".USDC-0X" + String(repeating: "12", count: 20)
            let exact = try progress(chain: chain, asset: asset, requested: checksum, observed: checksum)
            XCTAssertTrue(exact.isFinished)
            let wrongAddress = try progress(chain: chain, asset: asset, requested: checksum, observed: other)
            let wrongChain = try progress(chain: chain, asset: asset, requested: checksum, observed: checksum, observedChain: "BTC")
            let wrongAsset = try progress(chain: chain, asset: asset, requested: checksum, observed: checksum, observedAsset: "BTC.BTC")
            let wrongInbound = try progress(chain: chain, asset: asset, requested: checksum, observed: checksum,
                observedMemo: "OUT:" + String(repeating: "EF", count: 32))
            for mismatch in [wrongAddress, wrongChain, wrongAsset, wrongInbound] {
                XCTAssertNil(mismatch.outboundHash)
                XCTAssertFalse(mismatch.isFinished)
            }
        }
        // Base58 destinations must retain their case-sensitive identity.
        let tron = try TronSendCrypto.address(privateKey: Data(repeating: 1, count: 32))
        let exact = try progress(chain: "TRON", asset: "TRON.TRX", requested: tron, observed: tron)
        XCTAssertTrue(exact.isFinished)
        let altered = try progress(chain: "TRON", asset: "TRON.TRX", requested: tron, observed: tron.lowercased())
        XCTAssertNil(altered.outboundHash)
        XCTAssertFalse(altered.isFinished)
    }
}
