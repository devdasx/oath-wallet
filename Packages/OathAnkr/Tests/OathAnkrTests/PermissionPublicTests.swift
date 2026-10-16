import XCTest
@testable import OathAnkr

@MainActor final class PermissionPublicTests:XCTestCase {
    func testNileAccountControlRemovalPreservesOwner() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_TRON_CONTROL_FIXTURE"] else {throw XCTSkip("Isolated free Nile account-control fixture")}
        struct Fixture:Decodable {let key:String,sender:String,recipient:String,network:String}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard f.network=="nile" else {throw TronSendError.wrongNetwork}
        let client=try TronSendClient(network:.nile),configuration=try await client.accountPermissions(owner:f.sender)
        let control=try TronPermissionControl(configuration:configuration,permissionID:2,delegate:f.recipient)
        try control.validate(signer:f.sender)
        let removal=TronPermissionRemoval(contract:f.sender,spender:f.recipient,expected:"1",control:control)
        let plan=try await client.quote(sender:f.sender,recipient:f.sender,reference:"native",decimals:6,amount:"0",removal:removal)
        try await client.preflightPermission(plan)
        XCTAssertGreaterThanOrEqual(plan.fee,100_000_000)
        var key=try TronIdentity.hex(f.key);defer{key.resetBytes(in:0..<key.count)}
        let signed=try TronSendCrypto.sign(plan,privateKey:key)
        var receipt=try await client.submit(signed,plan:plan)
        for _ in 0..<45 {
            if [.confirmed,.failed,.expired].contains(receipt.outcome){break}
            try await Task.sleep(for:.seconds(2));receipt=try await client.status(signed,plan:plan)
        }
        XCTAssertEqual(receipt.outcome,.confirmed)
        let after=try await client.accountPermissions(owner:f.sender)
        XCTAssertTrue(try control.isRemoved(after))
        XCTAssertEqual(after["owner_permission"],configuration["owner_permission"])
        XCTAssertEqual(after["witness_permission"],configuration["witness_permission"])
        let current=try TronPermissionControl(configuration:after,permissionID:2,delegate:f.recipient)
        XCTAssertEqual(current.actives[0].threshold,control.actives[0].threshold)
        XCTAssertEqual(current.actives[0].operations,control.actives[0].operations)
        XCTAssertEqual(current.actives[0].keys.count,control.actives[0].keys.count-1)
        do {try await client.preflightPermission(plan);XCTFail("Stale full-configuration update accepted")} catch {XCTAssertEqual(error as? PermissionError,.changed)}
        print("PERMISSION_NILE_CONTROL_CONFIRMED hash=\(signed.hash) fee=\(receipt.fee ?? 0) owner_preserved=true")
    }
    func testNileAllowanceRemoval() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_TRON_PERMISSION_FIXTURE"] else { throw XCTSkip("Isolated free Nile fixture required") }
        struct Fixture:Decodable {let key:String,sender:String,recipient:String,network:String,permissionContract:String}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard f.network=="nile" else { throw TronSendError.wrongNetwork }
        var key=try TronIdentity.hex(f.key);defer {key.resetBytes(in:0..<key.count)}
        let client=try TronSendClient(network:.nile),removal=TronPermissionRemoval(contract:f.permissionContract,spender:f.recipient,expected:"123456")
        let before=try await client.permissionAllowance(owner:f.sender,contract:f.permissionContract,spender:f.recipient);XCTAssertEqual(before,"123456")
        let plan=try await client.quote(sender:f.sender,recipient:f.permissionContract,reference:"native",decimals:6,amount:"0",removal:removal)
        XCTAssertGreaterThan(plan.fee,0)
        let signed=try TronSendCrypto.sign(plan,privateKey:key)
        var receipt=try await client.submit(signed,plan:plan)
        for _ in 0..<45 {
            if [.confirmed,.failed,.expired].contains(receipt.outcome) {break}
            try await Task.sleep(for:.seconds(2));receipt=try await client.status(signed,plan:plan)
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertLessThanOrEqual(try XCTUnwrap(receipt.fee),plan.fee)
        let after=try await client.permissionAllowance(owner:f.sender,contract:f.permissionContract,spender:f.recipient);XCTAssertEqual(after,"0")
        print("PERMISSION_NILE_CONFIRMED hash=\(signed.hash) fee=\(receipt.fee ?? 0) allowance=0")
    }
    func testSolanaLegacyAnd2022DelegateRemoval() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_SOLANA_PERMISSION_FIXTURE"] else { throw XCTSkip("Isolated free Solana fixture required") }
        struct Fixture:Decodable {let seed:String,sender:String,network:String,permissions:[SolanaPermissionRemoval]}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard let network=SolanaSendNetwork(rawValue:f.network),network != .mainnet else {throw SolanaSendError.wrongNetwork}
        var key=try TronIdentity.hex(f.seed);defer{key.resetBytes(in:0..<key.count)}
        let client=try SolanaSendClient(network:network)
        XCTAssertEqual(f.permissions.count,2)
        let discovered=try await client.permissions(owner:f.sender)
        for r in f.permissions {
            XCTAssertTrue(discovered.permissions.contains{$0.tokenAccount==r.account && $0.spender==r.delegate})
            let plan=try await client.quoteRemoval(owner:f.sender,removal:r);try await client.preflight(plan)
            let signed=try SolanaSendCrypto.sign(plan,privateKey:key)
            var receipt=try await client.submit(signed,plan:plan)
            for _ in 0..<45 {
                if [.confirmed,.failed,.expired].contains(receipt.outcome) {break}
                try await Task.sleep(for:.seconds(2));receipt=try await client.status(signed,plan:plan)
            }
            XCTAssertEqual(receipt.outcome,.confirmed)
            let removed=try await client.permissionRemoved(owner:f.sender,removal:r);XCTAssertTrue(removed)
            print("PERMISSION_SOLANA_CONFIRMED hash=\(signed.hash) fee=\(receipt.fee ?? 0) delegate_removed=true")
        }
    }
}
