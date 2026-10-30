import XCTest
@testable import OathAnkr

final class PermissionReviewSelectionTests: XCTestCase {
    private func permission(_ network: String = "bnb", kind: WalletPermission.Kind = .token,
                            amount: String = "100") -> WalletPermission {
        .init(network: network, owner: "0x" + String(repeating: "1", count: 40),
              contract: "0x" + String(repeating: "3", count: 40),
              spender: "0x" + String(repeating: "2", count: 40), kind: kind, amount: amount)
    }
    func testSheetPayloadCannotExistWithoutItsWalletAndSelection() throws {
        XCTAssertNil(PermissionReviewSelection(walletID: "wallet", items: []))
        XCTAssertNil(PermissionReviewSelection(walletID: "", items: [permission()]))
        XCTAssertNil(PermissionReviewSelection(walletID: "wallet", items: [permission(), permission()]))
        var source = [permission()]
        let review = try XCTUnwrap(PermissionReviewSelection(walletID: "original", items: source))
        source = [permission("celo")]
        XCTAssertEqual(review.walletID, "original")
        XCTAssertEqual(review.items.map(\.network), ["bnb"])
        XCTAssertNotEqual(review.id, PermissionReviewSelection(walletID: "original", items: review.items)?.id)
    }
    func testEverySupportedReviewNetworkRetainsSelection() throws {
        let networks = EVMSendNetwork.allCases.filter { !$0.isTestnet && $0 != .arc }.map(\.rawValue) + ["tron", "solana"]
        let review = try XCTUnwrap(PermissionReviewSelection(walletID: "wallet", items: networks.map { permission($0) }))
        XCTAssertEqual(review.items.map(\.network), networks)
    }
    func testPermit2DisplaysAllowanceNotExpiryOrNonceAndControlHasNoTokenAmount() {
        let permit = permission(kind: .permit2, amount: "12345:2000000000:7")
        XCTAssertEqual(permit.tokenAllowance, "12345")
        XCTAssertFalse(permit.hasUnlimitedTokenAllowance)
        XCTAssertTrue(permission(kind: .permit2, amount: "1461501637330902918203684832716283019655932542975:2000000000:7").hasUnlimitedTokenAllowance)
        XCTAssertTrue(permission(amount: "115792089237316195423570985008687907853269984665640564039457584007913129639935").hasUnlimitedTokenAllowance)
        for kind in [WalletPermission.Kind.collectible, .collection, .accountControl, .delegation, .permit2Nonce] {
            XCTAssertNil(permission(kind: kind).tokenAllowance)
        }
    }
}

@MainActor final class PermissionNetworkPreparationTests: XCTestCase {
    func testEverySupportedEVMNetworkPreparesZeroValueRemovalAndRejectsUnfundedRemoval() async throws {
        let owner = "0x" + String(repeating: "1", count: 40)
        let contract = "0x" + String(repeating: "3", count: 40)
        let spender = "0x" + String(repeating: "2", count: 40)
        let removal = EVMPermissionRemoval(kind: .token, contract: contract, spender: spender, expected: "1")
        for network in EVMSendNetwork.allCases where !network.isTestnet && network != .arc {
            for funded in [true, false] {
                let transport = EVMSendFixtureTransport(network: network, nativeBalance: funded ? "1000000000000000000" : "0", gasEstimate: 21_000)
                let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
                do {
                    let plan = try await client.quote(sender: owner, recipient: contract, reference: "native", decimals: 18, amount: "0", removal: removal)
                    XCTAssertTrue(funded, network.rawValue)
                    XCTAssertEqual(plan.amount, "0")
                    XCTAssertEqual(plan.receiver, contract)
                    XCTAssertGreaterThan(plan.fee, 0)
                    XCTAssertEqual(plan.removal, removal)
                    try await client.preflight(plan)
                    let scope = try PermissionBatchScope.evm(sendID: UUID().uuidString, walletID: "wallet", accountID: "account", plan: plan)
                    XCTAssertEqual(scope.network, network.rawValue)
                    XCTAssertEqual(scope.maximumFee, plan.fee)
                } catch {
                    XCTAssertFalse(funded, "\(network.rawValue): \(error)")
                    XCTAssertTrue(error as? EVMSendError == .insufficientFunds || error is SendFeeFundingError, "\(network.rawValue): \(error)")
                }
                let counts = await transport.counts()
                XCTAssertEqual(counts.1, 0, "Reviews must never broadcast")
            }
        }
    }
}

final class PermissionNonEVMReviewTests: XCTestCase {
    func testTronRemovalScopeOnlyRevokesAndNeverTransfers() throws {
        let owner = try TronSendCrypto.address(privateKey:Data(repeating:1,count:32))
        let contract = try TronSendCrypto.address(privateKey:Data(repeating:2,count:32))
        let spender = try TronSendCrypto.address(privateKey:Data(repeating:3,count:32))
        let removal = TronPermissionRemoval(contract:contract,spender:spender,expected:"100")
        XCTAssertEqual(try removal.calldata().suffix(32),Data(repeating:0,count:32))
        let now = Date.now, timestamp = UInt64(now.timeIntervalSince1970 * 1000)
        let plan = TronSendPlan(network:.mainnet,sender:owner,recipient:contract,reference:"native",
            amount:"0",requestedAmount:"0",assetBalance:"100000000",decimals:6,nativeBalance:100_000_000,
            fee:10_000_000,estimatedFee:5_000_000,feeLimit:9_000_000,energyPrice:100,bandwidthPrice:1000,
            blockID:"0000000000000001"+String(repeating:"a",count:48),blockNumber:1,
            timestamp:timestamp,expiration:timestamp+180_000,createdAt:now,removal:removal)
        let scope = try PermissionBatchScope.tron(sendID:UUID().uuidString,walletID:"wallet",accountID:"account",plan:plan)
        XCTAssertEqual(scope.network,"tron")
        XCTAssertEqual(scope.removal,.tron(removal))
        XCTAssertEqual(plan.remaining,"90000000")
        let signed = try TronSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32))
        try TronSendCrypto.verify(signed,plan:plan)
    }

    func testSolanaAndToken2022RemovalScopesOnlyRevokeTheSelectedDelegate() throws {
        let owner = try SolanaSendCrypto.address(privateKey:Data(repeating:1,count:32))
        let account = try SolanaSendCrypto.address(privateKey:Data(repeating:2,count:32))
        let delegate = try SolanaSendCrypto.address(privateKey:Data(repeating:3,count:32))
        let mint = try SolanaSendCrypto.address(privateKey:Data(repeating:4,count:32))
        for program in [SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program] {
            let removal = SolanaPermissionRemoval(account:account,mint:mint,program:program,delegate:delegate,amount:100)
            let plan = SolanaSendPlan(network:.mainnet,sender:owner,recipient:account,
                requestedAmount:0,amount:0,assetBalance:100_000,nativeBalance:100_000,
                blockhash:mint,lastValidBlockHeight:100,slot:90,transactionFee:5_000,removal:removal)
            let scope = try PermissionBatchScope.solana(sendID:UUID().uuidString,walletID:"wallet",accountID:"account",plan:plan)
            XCTAssertEqual(scope.network,"solana")
            XCTAssertEqual(scope.removal,.solana(removal))
            XCTAssertEqual(plan.remaining,95_000)
            // The production serializer's final instruction is SPL Revoke (5),
            // with only token account + owner; no transfer amount/recipient.
            XCTAssertEqual(try SolanaSendCrypto.message(plan).suffix(2),Data([1,5]))
            let signed = try SolanaSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32))
            try SolanaSendCrypto.verify(signed,plan:plan)
        }
    }
}
