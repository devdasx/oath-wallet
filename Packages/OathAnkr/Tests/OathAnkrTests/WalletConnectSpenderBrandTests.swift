import XCTest
@testable import OathAnkr

final class WalletConnectSpenderBrandTests: XCTestCase {
    private let permit2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"

    func testBNBApprovalIdentifiesActualSpenderWithoutInventingSwap() throws {
        let owner = "0x4444444444444444444444444444444444444444"
        let data = "0x095ea7b3" + String(repeating: "0", count: 24)
            + permit2.dropFirst(2).lowercased() + String(repeating: "f", count: 64)
        let request = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: [[
            "from": owner, "to": "0x55d398326f99059ff775485246999027b3197955", "data": data, "value": "0x0"
        ]]), account: owner, chainID: 56)
        let action = WalletConnectEVMAction(request)
        XCTAssertEqual(action.kind, .approval)
        XCTAssertTrue(action.isUnlimited)
        let spender = try XCTUnwrap(action.fields.first { $0.label == .spender }?.value)
        XCTAssertEqual(WalletConnectSpenderBrand.resolve(chainID: 56, address: spender)?.name, "Uniswap Permit2")
        XCTAssertTrue(WalletConnectSwapReview(request).routes.isEmpty)
    }

    func testBNBSwapTokensResolveFromSearchCatalogByContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = TokenDiscoveryCatalog(directory: directory)
        for (address, symbol, coinID) in [
            // CoinGecko calls this deployment BSC-USD; identity must be the
            // contract, never a ticker alias. On-chain metadata supplies USDT.
            ("0x55d398326f99059ff775485246999027b3197955", "BSC-USD", "binance-bridged-usdt-bnb-smart-chain"),
            ("0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", "USDC", "binance-bridged-usdc-bnb-smart-chain")
        ] {
            let entries = await catalog.search(address, networks: ["bnb"], limit: 1)
            let token = try XCTUnwrap(entries.first)
            XCTAssertEqual(token.network, "bnb")
            XCTAssertEqual(token.reference, address)
            XCTAssertEqual(token.symbol.uppercased(), symbol)
            XCTAssertEqual(token.coinID, coinID)
            XCTAssertFalse(token.name.isEmpty)
        }
    }

    func testBNBPermitSpenderIsRouterRatherThanVerifyingPermit2Contract() {
        let router = "0xDc264714F68d84CF29BC605589405E78bDBE7C9f"
        XCTAssertEqual(WalletConnectSpenderBrand.resolve(chainID: 56, address: router)?.name, "Uniswap Universal Router")
        XCTAssertNotEqual(WalletConnectSpenderBrand.resolve(chainID: 56, address: router)?.name,
                          WalletConnectSpenderBrand.resolve(chainID: 56, address: permit2)?.name)
        XCTAssertNil(WalletConnectSpenderBrand.resolve(chainID: 1, address: router))
    }

    func testBrandRequiresExactDeploymentAndChain() {
        for chain: UInt64 in [1, 56, 137, 8453, 42220, 130] {
            XCTAssertEqual(WalletConnectSpenderBrand.resolve(chainID: chain, address: permit2)?.name, "Uniswap Permit2")
        }
        for chain: UInt64 in [0, 5042, 999999] {
            XCTAssertNil(WalletConnectSpenderBrand.resolve(chainID: chain, address: permit2))
        }
        for address in ["Permit2", " " + permit2, permit2 + "0", "0x000000000022d473030f116ddee9f6b43ac78ba2"] {
            XCTAssertNil(WalletConnectSpenderBrand.resolve(chainID: 56, address: address))
        }
    }
}
