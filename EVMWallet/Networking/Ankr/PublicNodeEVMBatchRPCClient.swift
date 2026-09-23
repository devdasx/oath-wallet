import Foundation

private struct PublicNodeEVMBatchRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [AnyEncodable]
}

private struct PublicNodeEVMBatchResponse: Decodable {
    let id: Int?
    let result: String?
    let error: PublicNodeEVMBatchErrorPayload?
    let containsResult: Bool

    private enum CodingKeys: String, CodingKey {
        case id, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        containsResult = container.contains(.result)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        error = try container.decodeIfPresent(
            PublicNodeEVMBatchErrorPayload.self,
            forKey: .error
        )
    }
}

private struct PublicNodeEVMBatchErrorPayload: Decodable {
    let code: Int
    let message: String
}

/// Strict JSON-RPC batch transport for PublicNode portfolio reads. One HTTP
/// request carries chain validation, native balance, and every catalog
/// `balanceOf` call. Response order is irrelevant because each result is
/// bound to its request ID.
struct PublicNodeEVMBatchRPCClient: PublicNodeEVMBalanceRPC {
    private struct Target: Sendable {
        let operation: String
        let contractAddress: String?
    }

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession?, endpoint: URL) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func chainID() async throws -> String {
        try await singleResult(
            method: "eth_chainId",
            params: [],
            target: Target(operation: "eth_chainId", contractAddress: nil)
        )
    }

    func nativeBalance(address: String) async throws -> String {
        guard AnkrAPIClient.isValidAddress(address) else {
            throw PublicNodeEVMBalanceError.invalidWalletAddress
        }
        return try await singleResult(
            method: "eth_getBalance",
            params: [AnyEncodable(address), AnyEncodable("latest")],
            target: Target(operation: "eth_getBalance", contractAddress: nil)
        )
    }

    func tokenBalance(
        ownerAddress: String,
        contractAddress: String
    ) async throws -> String {
        let call = try tokenCall(
            ownerAddress: ownerAddress,
            contractAddress: contractAddress
        )
        return try await singleResult(
            method: "eth_call",
            params: call,
            target: Target(
                operation: "eth_call",
                contractAddress: contractAddress.lowercased()
            )
        )
    }

    func accountBalances(
        ownerAddress: String,
        contractAddresses: [String]
    ) async throws -> PublicNodeEVMBalanceBatchResult {
        guard AnkrAPIClient.isValidAddress(ownerAddress) else {
            throw PublicNodeEVMBalanceError.invalidWalletAddress
        }
        let normalizedContracts = contractAddresses.map { $0.lowercased() }
        guard Set(normalizedContracts).count == normalizedContracts.count,
              normalizedContracts.allSatisfy({
                  AnkrAPIClient.isValidAddress($0)
                      && $0 != AnkrAPIClient.zeroAddress
              })
        else {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "invalid_contract_inventory",
                message: "The contract inventory is invalid or duplicated."
            )
        }

        var requests = [
            PublicNodeEVMBatchRequest(
                id: 1,
                method: "eth_chainId",
                params: []
            ),
            PublicNodeEVMBatchRequest(
                id: 2,
                method: "eth_getBalance",
                params: [
                    AnyEncodable(ownerAddress),
                    AnyEncodable("latest")
                ]
            )
        ]
        var targets = [
            1: Target(operation: "eth_chainId", contractAddress: nil),
            2: Target(operation: "eth_getBalance", contractAddress: nil)
        ]
        requests.reserveCapacity(normalizedContracts.count + 2)
        targets.reserveCapacity(normalizedContracts.count + 2)
        for (index, contract) in normalizedContracts.enumerated() {
            let identifier = index + 3
            requests.append(
                PublicNodeEVMBatchRequest(
                    id: identifier,
                    method: "eth_call",
                    params: try tokenCall(
                        ownerAddress: ownerAddress,
                        contractAddress: contract
                    )
                )
            )
            targets[identifier] = Target(
                operation: "eth_call",
                contractAddress: contract
            )
        }

        let values = try await execute(requests, targets: targets)
        guard let chainID = values[1] else {
            throw missingResult(for: targets[1]!)
        }
        guard let native = values[2] else {
            throw missingResult(for: targets[2]!)
        }
        var tokenBalances: [String: String] = [:]
        tokenBalances.reserveCapacity(normalizedContracts.count)
        for (index, contract) in normalizedContracts.enumerated() {
            guard let value = values[index + 3] else {
                throw missingResult(for: targets[index + 3]!)
            }
            tokenBalances[contract] = value
        }
        return PublicNodeEVMBalanceBatchResult(
            chainID: chainID,
            nativeBalance: native,
            tokenBalancesByContract: tokenBalances
        )
    }

    private func singleResult(
        method: String,
        params: [AnyEncodable],
        target: Target
    ) async throws -> String {
        let values = try await execute(
            [PublicNodeEVMBatchRequest(id: 1, method: method, params: params)],
            targets: [1: target]
        )
        guard let value = values[1] else { throw missingResult(for: target) }
        return value
    }

    private func execute(
        _ requests: [PublicNodeEVMBatchRequest],
        targets: [Int: Target]
    ) async throws -> [Int: String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requests)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "url_\(error.code.rawValue)",
                message: Self.sanitized(error.localizedDescription)
            )
        } catch {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: SendTransactionSubmissionError.sanitizedErrorType(error),
                message: Self.sanitized(String(describing: error))
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "non_http_response",
                message: "PublicNode returned a non-HTTP response."
            )
        }
        let decoded = try? JSONDecoder().decode(
            [PublicNodeEVMBatchResponse].self,
            from: data
        )
        guard (200...299).contains(http.statusCode) else {
            if let failure = decoded?.first(where: { $0.error != nil }),
               let payload = failure.error,
               let target = failure.id.flatMap({ targets[$0] }) {
                throw providerError(payload, target: target)
            }
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "http_\(http.statusCode)",
                message: "PublicNode returned HTTP \(http.statusCode)."
            )
        }
        guard let decoded, decoded.count == requests.count else {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "invalid_response_count",
                message: "The batch response count did not match the request."
            )
        }

        var values: [Int: String] = [:]
        values.reserveCapacity(decoded.count)
        for item in decoded {
            guard let identifier = item.id,
                  let target = targets[identifier],
                  values[identifier] == nil
            else {
                throw PublicNodeEVMBalanceError.providerRead(
                    operation: "batch",
                    contractAddress: nil,
                    code: "invalid_response_id",
                    message: "The batch response contained an unknown or duplicate ID."
                )
            }
            if let payload = item.error {
                throw providerError(payload, target: target)
            }
            guard item.containsResult, let result = item.result else {
                throw missingResult(for: target)
            }
            values[identifier] = result
        }
        return values
    }

    private func tokenCall(
        ownerAddress: String,
        contractAddress: String
    ) throws -> [AnyEncodable] {
        let owner = ownerAddress.lowercased()
        let contract = contractAddress.lowercased()
        guard AnkrAPIClient.isValidAddress(owner),
              AnkrAPIClient.isValidAddress(contract),
              contract != AnkrAPIClient.zeroAddress
        else {
            throw PublicNodeEVMBalanceError.invalidWalletAddress
        }
        let encodedOwner = String(repeating: "0", count: 24)
            + owner.dropFirst(2)
        return [
            AnyEncodable([
                "to": contract,
                "data": "0x70a08231" + encodedOwner
            ]),
            AnyEncodable("latest")
        ]
    }

    private func providerError(
        _ payload: PublicNodeEVMBatchErrorPayload,
        target: Target
    ) -> PublicNodeEVMBalanceError {
        .providerRead(
            operation: target.operation,
            contractAddress: target.contractAddress,
            code: "rpc_\(payload.code)",
            message: Self.sanitized(payload.message)
        )
    }

    private func missingResult(
        for target: Target
    ) -> PublicNodeEVMBalanceError {
        .providerRead(
            operation: target.operation,
            contractAddress: target.contractAddress,
            code: "missing_result",
            message: "The JSON-RPC response did not contain a result."
        )
    }

    private static func sanitized(_ value: String) -> String {
        let clean = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(
            (clean.isEmpty ? "empty_provider_message" : clean).prefix(500)
        )
    }
}
