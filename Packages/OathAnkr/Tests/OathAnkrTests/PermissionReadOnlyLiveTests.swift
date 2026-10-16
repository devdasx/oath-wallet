import XCTest
@testable import OathAnkr

private struct PermissionReadOnlyTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let allowed: Set<String> = ["eth_chainId", "eth_blockNumber", "eth_getLogs", "eth_getBlockByNumber", "eth_getCode",
            "eth_getBalance", "eth_getTransactionCount", "eth_gasPrice", "eth_estimateGas", "eth_call"]
        for call in payload.array ?? [payload] {
            guard let method = call["method"].string, allowed.contains(method) else {
                XCTFail("Read-only permission check attempted a disallowed method")
                throw EVMSendError.configuration
            }
        }
        return try await AnkrHTTPTransport().send(request)
    }
}

@MainActor final class PermissionReadOnlyLiveTests: XCTestCase {
    func testBasePublicAllowanceQuoteAndPreflightWithoutSigning() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PERMISSION_BASE_READ"] == "1" else {
            throw XCTSkip("Opt-in public read-only Base fee check")
        }
        let endpoint: URL
        if let configuration = ProcessInfo.processInfo.environment["OATH_EVM_READ_CONFIG"] {
            let values = try PropertyListDecoder().decode([String: String].self,
                from: Data(contentsOf: URL(fileURLWithPath: configuration)))
            let key = try XCTUnwrap(values["AnkrAPIKey"])
            endpoint = URL(string: "https://rpc.ankr.com/base")!.appendingPathComponent(key)
        } else { endpoint = URL(string: "https://mainnet.base.org")! }
        let transport = PermissionReadOnlyTransport()
        func read(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(SolanaJSON.object([
                "jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": .array(params)]))
            let (data, status) = try await transport.send(request)
            guard status == 200, data.count < 4_194_304 else { throw EVMSendError.http(status) }
            let result = try JSONDecoder().decode(SolanaJSON.self, from: data)
            guard result["id"].integer == 1, result["jsonrpc"].string == "2.0", result["error"].isNull else {
                throw EVMSendError.malformed
            }
            return result["result"]
        }
        let chain = try await EVMSendClient.uint(read("eth_chainId", []))
        XCTAssertEqual(chain, EVMSendNetwork.base.chainID)
        let height = try await EVMSendClient.uint(read("eth_blockNumber", []))
        let contract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        let logs = try await read("eth_getLogs", [.object([
            "address": .string(contract), "topics": .array([.string(PermissionDiscovery.approval)]),
            "fromBlock": .string("0x" + String(height - min(height, 100), radix: 16)),
            "toBlock": .string("0x" + String(height, radix: 16))])])
        let entries = try XCTUnwrap(logs.array)
        let client = try EVMSendClient(network: .base, endpoints: [endpoint], transport: transport)
        var candidates = [WalletPermission]()
        for log in entries.reversed() {
            guard let topics = log["topics"].array, topics.count == 3,
                  let ownerWord = topics[1].string, ownerWord.count == 66,
                  try EVMSendClient.quantity(log["data"]) != "0" else { continue }
            let owner = "0x" + ownerWord.suffix(40)
            guard let permission = try PermissionDiscovery.candidate(log, network: "base", owner: owner),
                  !candidates.contains(where: { $0.id == permission.id }) else { continue }
            candidates.append(permission)
            if candidates.count == 16 { break }
        }
        XCTAssertFalse(candidates.isEmpty, "No recent public allowance sample")
        var failures = [String]()
        for permission in candidates {
            do {
                // Smart accounts may require a bundler/paymaster and are not
                // representative of this wallet's locally signed EOA path.
                guard try await read("eth_getCode", [.string(permission.owner), .string("latest")]).string == "0x" else { continue }
                let initial = EVMPermissionRemoval(kind: .token, contract: contract, spender: permission.spender, expected: "1")
                let amount = try await client.permissionState(owner: permission.owner, removal: initial)
                guard amount != "0" else { continue }
                let removal = EVMPermissionRemoval(kind: .token, contract: contract, spender: permission.spender, expected: amount)
                let plan = try await PermissionPreparation.run(chain: "base") {
                    try await client.quote(sender: permission.owner, recipient: contract, reference: "native", decimals: 18, amount: "0", removal: removal)
                }
                try await client.preflight(plan)
                XCTAssertEqual(plan.amount, "0"); XCTAssertEqual(plan.requestedAmount, "0")
                XCTAssertGreaterThan(plan.extraFee, 0); XCTAssertGreaterThan(plan.fee, plan.extraFee)
                XCTAssertFalse(EVMSendAmount.less(plan.nativeBalance, String(plan.fee)))
                print("PERMISSION_BASE_READ quote=passed preflight=passed gas=\(plan.gasLimit) fee=\(plan.fee) l1_operator_reserve=\(plan.extraFee) broadcasts=0")
                return
            } catch {
                failures.append((error as? EVMSendError).map { String(describing: $0) } ?? "read_or_permission_changed")
            }
        }
        XCTFail("No public sample completed quote/preflight: " + failures.joined(separator: ","))
    }
}
