import XCTest
@testable import OathAnkr

@MainActor final class EVMSelfTransferTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32)
    private let token = "0x" + String(repeating: "3", count: 40)

    private func aliases(_ owner: String, network: EVMSendNetwork) throws -> [String] {
        var result = [owner, "0x" + owner.dropFirst(2).uppercased()]
        if network.isFilecoin { result.append(try FilecoinIdentity.delegated(owner, testnet: network.isTestnet)) }
        if network.isIoTeX {
            let native = try IoTeXIdentity.native(owner)
            result += [native, native.uppercased()]
        }
        return result
    }

    func testEveryEVMNetworkRejectsNativeAndTokenSelfQuotesBeforeRPC() async throws {
        let owner = try EVMSendCrypto.address(privateKey: key)
        for network in EVMSendNetwork.allCases {
            let transport = EVMSendFixtureTransport(network: network)
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
            for recipient in try aliases(owner, network: network) {
                for reference in ["native", token] {
                    for maximum in [false, true] {
                        do {
                            _ = try await client.quote(sender: owner, recipient: recipient, reference: reference,
                                decimals: reference == "native" ? 18 : 6, amount: "1", maximum: maximum)
                            XCTFail("Self-send quote accepted on \(network.rawValue)")
                        } catch { XCTAssertEqual(error as? EVMSendError, .sameRecipient, network.rawValue) }
                    }
                }
            }
            let counts = await transport.counts()
            XCTAssertEqual(counts.0, 0, "Local recipient rejection must precede all network work")
            XCTAssertEqual(counts.1, 0)
        }
    }

    func testSavedSelfTransferPlansCannotReachSigning() throws {
        let owner = try EVMSendCrypto.address(privateKey: key)
        for network in EVMSendNetwork.allCases {
            for reference in ["native", token] {
                let plan = EVMSendPlan(network: network, sender: owner, recipient: owner, reference: reference,
                    decimals: reference == "native" ? 18 : 6, requestedAmount: "1", amount: "1",
                    assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
                    nonce: 1, gasLimit: network.minimumGas, maxFeePerGas: 1_000_000_000,
                    maxPriorityFeePerGas: 0, blockHeight: 1)
                let restored = try JSONDecoder().decode(EVMSendPlan.self, from: JSONEncoder().encode(plan))
                XCTAssertThrowsError(try restored.validate(checkAge: false)) {
                    XCTAssertEqual($0 as? EVMSendError, .sameRecipient)
                }
                XCTAssertThrowsError(try EVMSendCrypto.sign(restored, privateKey: key)) {
                    XCTAssertEqual($0 as? EVMSendError, .sameRecipient)
                }
            }
        }
    }

    func testMultisigSelfQuotesAndAliasesRejectBeforeRPC() async throws {
        let owners = try [key, Data(repeating: 2, count: 32)].map(EVMSendCrypto.address)
        let policy = try EVMMultisigPolicy(required: 2, owners: owners, salt: Data(repeating: 7, count: 32),
            executor: EVMSendCrypto.address(privateKey: Data(repeating: 9, count: 32)))
        for network in EVMSendNetwork.allCases {
            let transport = EVMSendFixtureTransport(network: network)
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
            for recipient in try aliases(policy.address, network: network) {
                for reference in ["native", token] {
                    do {
                        _ = try await client.quoteMultisig(policy: policy, recipient: recipient, reference: reference,
                            decimals: reference == "native" ? 18 : 6, amount: "1")
                        XCTFail("Multisig self-send quote accepted")
                    } catch { XCTAssertEqual(error as? EVMSendError, .sameRecipient, network.rawValue) }
                }
            }
            let counts = await transport.counts()
            XCTAssertEqual(counts.0, 0)
        }
    }

    func testExplicitDAppCallsToSelfRemainSeparateFromOrdinarySend() throws {
        let owner = try EVMSendCrypto.address(privateKey: key)
        for network in EVMSendNetwork.allCases {
            let plan = EVMSendPlan(network: network, sender: owner, recipient: owner, reference: "native", decimals: 18,
                requestedAmount: "1", amount: "1", assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
                nonce: 1, gasLimit: network.minimumGas, maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 0,
                blockHeight: 1, call: try EVMContractCall(hex: "0x"))
            try plan.validate()
            try EVMSendCrypto.verify(EVMSendCrypto.sign(plan, privateKey: key), plan: plan)
        }
    }
}
