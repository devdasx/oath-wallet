import XCTest
@testable import OathAnkr

/// Explicitly opt-in, disposable Sepolia funds only. Secrets are loaded from a
/// mode-0600 temporary fixture and never written to test output or the repo.
@MainActor final class EVMMultisigPublicTests: XCTestCase {
    private var network: EVMSendNetwork {
        ProcessInfo.processInfo.environment["OATH_SAFE_L2"] == "1" ? .arbitrumSepolia : .ethereumSepolia
    }
    private var directory: URL {
        URL(fileURLWithPath: network == .arbitrumSepolia ? "/tmp/oath-evm-multisig-arbitrum" : "/tmp/oath-evm-multisig-public")
    }
    private struct Fixture: Decodable {
        let network: String, recipient: String, token: String
        let cases: [Wallet]
        struct Wallet: Decodable {
            let required: Int, owners: [Owner], executorKey: String, executor: String, salt: String, address: String, funded: Bool
        }
        struct Owner: Decodable { let key: String, address: String, source: String }
    }
    private struct Record: Codable {
        let label: String, plan: EVMSendPlan, signed: EVMSignedSend
    }
    private func client() throws -> EVMSendClient {
        try .init(network: network, endpoints: [URL(string: network == .arbitrumSepolia ? "https://sepolia-rollup.arbitrum.io/rpc" : "https://ethereum-sepolia-rpc.publicnode.com")!])
    }
    private func readRecords() throws -> [Record] {
        let file = directory.appendingPathComponent("transactions.json")
        return FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) : []
    }
    private func save(_ records: [Record]) throws {
        let file = directory.appendingPathComponent("transactions.json")
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func included(_ signed: EVMSignedSend, client: EVMSendClient) async throws -> SolanaJSON {
        for _ in 0..<60 {
            let receipt = try await client.rpc("eth_getTransactionReceipt", [.string(signed.hash)])
            if !receipt.isNull {
                guard try EVMSendClient.uint(receipt["status"]) == 1 else { throw EVMSendError.execution }
                return receipt
            }
            try await Task.sleep(for: .seconds(4))
        }
        throw EVMSendError.transport
    }
    func testPublicSepoliaDeployNativeERC20AndRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SAFE_PUBLIC"] == "1" else { throw XCTSkip("Opt-in public Sepolia test") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("wallets.json")))
        XCTAssertEqual(fixture.network,network.rawValue)
        let client = try client(); var records = try readRecords()
        for c in fixture.cases {
            XCTAssertTrue(c.funded)
            let policy = try EVMMultisigPolicy(required: c.required, owners: c.owners.map(\.address), salt: TronIdentity.hex(c.salt), executor: c.executor)
            XCTAssertEqual(try policy.address,c.address) // Independently computed by ethers + official Safe artifact.
            let executor = try TronIdentity.hex(c.executorKey), keys = try c.owners.map { try TronIdentity.hex($0.key) }
            let prefix = "\(c.required)-of-\(c.owners.count)"
            let steps: [(String,String,String,Bool)] = [("setup","native","0",false),("native","native","12345",false),("token",fixture.token,"12345",false),("token-max",fixture.token,"0",true),("native-max","native","0",true)]
            for (label,ref,amount,maximum) in steps {
                let name = prefix + ":" + label
                if let existing = records.first(where: { $0.label == name }) {
                    _ = try await client.submit(existing.signed, plan: existing.plan)
                    _ = try await included(existing.signed,client:client)
                    continue
                }
                let setup = label == "setup"
                let recipient = setup ? EVMMultisigPolicy.factory : fixture.recipient
                let before = try await client.balance(owner: fixture.recipient, reference: ref)
                let funds = try await client.balance(owner: c.address, reference: ref)
                let payer = try await client.balance(owner: c.executor, reference: "native")
                let p = try await client.quoteMultisig(policy: policy, recipient: recipient, reference: ref, decimals: ref == "native" ? 18:6, amount: amount, maximum: maximum, setup: setup)
                if !setup {
                    XCTAssertThrowsError(try EVMMultisigCrypto.sign(p, keys: Array(keys.prefix(c.required-1)), executorKey: executor))
                }
                let signed = try EVMMultisigCrypto.sign(p, keys: setup ? []:Array(keys.suffix(c.required)), executorKey: executor)
                try await client.validateSignedMultisig(signed, plan: p)
                records.append(.init(label: name, plan: p, signed: signed)); try save(records)
                _ = try await client.submit(signed, plan: p, reconcileFirst: false)
                let receipt = try await included(signed,client:client)
                let fee = try EVMSendAmount.multiply(EVMSendClient.quantity(receipt["gasUsed"]),EVMSendClient.quantity(receipt["effectiveGasPrice"]))
                let payerAfter = try await client.balance(owner:c.executor,reference:"native")
                XCTAssertEqual(try EVMSendAmount.subtract(payer,payerAfter),fee)
                if setup {
                    let state = try await client.multisigState(policy); XCTAssertTrue(state.configured)
                } else {
                    let after = try await client.balance(owner: fixture.recipient, reference: ref), balance = try await client.balance(owner: c.address, reference: ref)
                    XCTAssertEqual(try EVMSendAmount.subtract(after,before),p.amount)
                    XCTAssertEqual(try EVMSendAmount.subtract(funds,balance),p.amount)
                    if maximum { XCTAssertEqual(balance,"0") }
                    _ = try await client.submit(signed,plan:p)
                    let again = try await client.balance(owner: fixture.recipient, reference: ref); XCTAssertEqual(again,after)
                }
                print("SAFE_\(network.rawValue)_INCLUDED \(name) \(signed.hash) exact_balance_delta=true")
            }
        }
    }
    func testPublicFinalityAndPersistedSignatureRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SAFE_FINALITY"] == "1" else { throw XCTSkip("Opt-in finality observation") }
        let client = try client(), records = try readRecords()
        XCTAssertEqual(records.count, network == .arbitrumSepolia ? 5 : 15)
        for r in records {
            let receipt = try await client.status(r.signed, plan: r.plan)
            guard receipt.outcome == .confirmed else { throw EVMSendError.busy }
            if r.plan.reference != "native" { XCTAssertEqual(receipt.deliveredAmount,r.plan.amount) }
            XCTAssertNotNil(receipt.fee); XCTAssertNotNil(receipt.height)
            let duplicate = try await client.submit(r.signed, plan:r.plan)
            guard duplicate.outcome == .confirmed else { throw EVMSendError.busy }
            print("SAFE_\(network.rawValue)_FINALIZED \(r.label) \(r.signed.hash)")
        }
    }
}
