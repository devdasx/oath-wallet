import Foundation
import XCTest
@testable import OathBitcoin

actor QueryFixture: BitcoinAddressQuerying {
    var replies: [String: BitcoinAddressState] = [:]
    var failure: String?
    var requested = Set<String>()
    var active = 0
    var peak = 0
    func configure(_ replies: [String: BitcoinAddressState], failure: String? = nil) { self.replies = replies; self.failure = failure }
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        if let failure, scriptHashes.contains(failure) { throw BitcoinError.disconnected }
        requested.formUnion(scriptHashes)
        return scriptHashes.map { replies[$0] ?? .init(confirmed: 0, unconfirmed: 0, history: [], unspent: []) }
    }
}

final class DiscoveryTests: XCTestCase, @unchecked Sendable {
    func testGapTwentyOnBothBranchesAndEveryType() async throws {
        let wallet = try BitcoinKeysTests.wallet()
        let query = QueryFixture()
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.addresses.count, 160)
        XCTAssertEqual(scan.total, 0)
        for branch in wallet.branches { XCTAssertEqual(scan.addresses.filter { $0.address.branchID == branch.id }.count, 20) }
        let peak = await query.peak; XCTAssertGreaterThan(peak, 1)
    }
    func testSpentHistoryExtendsGapAtBoundaryIncludingChange() async throws {
        let wallet = try BitcoinKeysTests.wallet()
        let branch = try XCTUnwrap(wallet.branches.first { $0.type == .taproot && $0.change == 1 })
        let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
        let query = QueryFixture()
        await query.configure([address.scriptHash: .init(confirmed: 0, unconfirmed: 0,
            history: [.init(txid: String(repeating: "1", count: 64), height: 100)], unspent: [])])
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.addresses.filter { $0.address.branchID == branch.id }.count, 40)
        XCTAssertEqual(scan.addresses.count, 180)
    }
    func testPriorIssuedAddressIsNotForgottenAfterRestart() async throws {
        let wallet = try BitcoinKeysTests.wallet(); let branch = wallet.branches[0]
        let scan = try await BitcoinDiscovery(query: QueryFixture()).scan(wallet, requiredThrough: [branch.id: 55])
        XCTAssertEqual(scan.addresses.filter { $0.address.branchID == branch.id }.count, 60)
    }
    func testBalancesAndOutputsFromEveryScriptAreCombined() async throws {
        let wallet = try BitcoinKeysTests.wallet(); let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        for (i, branch) in wallet.branches.enumerated() {
            let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
            let txid = String(repeating: String(i + 1), count: 64)
            replies[address.scriptHash] = .init(confirmed: 100, unconfirmed: -10,
                history: [.init(txid: txid, height: 100)], unspent: [.init(txid: txid, vout: 0, value: 90, height: 100)])
        }
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.confirmed, 800); XCTAssertEqual(scan.unconfirmed, -80); XCTAssertEqual(scan.total, 720)
        XCTAssertEqual(scan.addresses.flatMap { $0.state.unspent }.count, 8)
    }
    func testFinitePrivateKeyScanDoesNotInventTwentyAddresses() async throws {
        for compressed in [true, false] {
            let wallet = try BitcoinKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: compressed)
            let scan = try await BitcoinDiscovery(query: QueryFixture()).scan(wallet)
            XCTAssertEqual(scan.addresses.count, compressed ? 4 : 1)
        }
    }
    func testPersistenceValidationRejectsPartialGapAndForgedAddress() async throws {
        let wallet = try BitcoinKeysTests.wallet()
        let scan = try await BitcoinDiscovery(query: QueryFixture()).scan(wallet)
        XCTAssertNoThrow(try scan.validate(wallet: wallet, requiredThrough: [:]))

        let missingBranch = BitcoinScan(addresses: scan.addresses.filter {
            $0.address.branchID != wallet.branches[0].id
        }, completedAt: scan.completedAt)
        XCTAssertThrowsError(try missingBranch.validate(wallet: wallet, requiredThrough: [:]))
        let truncatedGap = BitcoinScan(addresses: Array(scan.addresses.dropLast()), completedAt: scan.completedAt)
        XCTAssertThrowsError(try truncatedGap.validate(wallet: wallet, requiredThrough: [:]))
        XCTAssertThrowsError(try scan.validate(wallet: wallet, requiredThrough: [wallet.branches[0].id: 20]))

        // The claimed script/hash remains unchanged, but the address displayed
        // to a user no longer belongs to that script. Never persist this record.
        let original = scan.addresses[0]
        let address = original.address
        let forged = BitcoinDerivedAddress(branchID: address.branchID, type: address.type,
            change: address.change, index: address.index, path: address.path,
            address: scan.addresses[1].address.address, script: address.script, scriptHash: address.scriptHash)
        let altered = BitcoinScan(addresses: [.init(address: forged, state: original.state)] + scan.addresses.dropFirst(),
                                  completedAt: scan.completedAt)
        XCTAssertThrowsError(try altered.validate(wallet: wallet, requiredThrough: [:]))
    }
    func testOneFailedTypeNeverReturnsPartialZero() async throws {
        let wallet = try BitcoinKeysTests.wallet(); let query = QueryFixture()
        let address = try BitcoinKeys.addresses(branch: wallet.branches.last!, range: 0..<1)[0]
        await query.configure([:], failure: address.scriptHash)
        do { _ = try await BitcoinDiscovery(query: query).scan(wallet); XCTFail("Partial scan accepted") }
        catch { XCTAssertEqual(error as? BitcoinError, .disconnected) }
    }
    func testPersistenceRejectsContradictoryPendingOutputHeights() async throws {
        for network in UTXONetwork.allCases {
            let wallet = try network.wallet(seed: Data(0..<32))
            let address = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
            let txid = String(repeating: "1", count: 64)
            let query = QueryFixture()
            await query.configure([address.scriptHash: .init(confirmed: 0, unconfirmed: 20_000,
                history: [.init(txid: txid, height: -1)], unspent: [.init(txid: txid, vout: 0, value: 20_000, height: 100)])])
            let scan = try await BitcoinDiscovery(query: query).scan(wallet)
            XCTAssertThrowsError(try scan.validate(wallet: wallet, requiredThrough: [:])) {
                XCTAssertEqual($0 as? BitcoinError, .inconsistentSnapshot)
            }
        }
    }
    func testDiscoveryLimitIsExplicitFailure() async throws {
        let wallet = try BitcoinKeysTests.wallet()
        do { _ = try await BitcoinDiscovery(query: QueryFixture(), maximumIndex: 20).scan(wallet, requiredThrough: [wallet.branches[0].id: 21]); XCTFail("Truncated scan accepted") }
        catch { XCTAssertEqual(error as? BitcoinError, .discoveryLimit) }
    }
    func testCancellationDoesNotCompleteDiscovery() async throws {
        let wallet = try BitcoinKeysTests.wallet()
        let task = Task { try await BitcoinDiscovery(query: QueryFixture()).scan(wallet) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan returned") } catch is CancellationError { }
    }
}
