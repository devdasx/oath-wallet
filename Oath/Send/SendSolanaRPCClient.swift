import Foundation

struct SendSolanaAccountState: Hashable, Sendable {
    let lamports: UInt64
    let dataLength: Int
}

private struct SendSolanaRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [SolanaJSONValue]
}

private struct SendSolanaRPCResponse: Decodable {
    let id: Int?
    let result: SolanaJSONValue?
    let error: SolanaRPCResponse.RPCError?
}

actor SendSolanaRPCClient {
    enum TokenProgram: Sendable {
        case legacy
        case token2022

        var address: String {
            switch self {
            case .legacy:
                SolanaConstants.tokenProgramID
            case .token2022:
                SolanaConstants.token2022ProgramID
            }
        }
    }

    private let endpoints: [URL]
    private let session: URLSession
    private var requestID = 0

    init(
        session: URLSession? = nil,
        endpoints: [URL]? = nil
    ) {
        self.endpoints = Self.unique(
            endpoints ?? Self.defaultEndpoints()
        )
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func latestBlockhash() async throws -> String {
        let result = try await call(
            method: "getLatestBlockhash",
            params: [
                .object(["commitment": .string("confirmed")])
            ]
        )
        guard let blockhash = result.object?["value"]?
            .object?["blockhash"]?.string,
            !blockhash.isEmpty
        else {
            throw invalidResponse("latest_blockhash")
        }
        return blockhash
    }

    func nativeBalance(address: String) async throws -> UInt64 {
        let result = try await call(
            method: "getBalance",
            params: [
                .string(address),
                .object(["commitment": .string("confirmed")])
            ]
        )
        guard let value = result.object?["value"]?.decimal,
              let balance = Self.exactUInt64(value)
        else {
            throw invalidResponse("native_balance")
        }
        return balance
    }

    func accountState(
        address: String
    ) async throws -> SendSolanaAccountState? {
        guard let value = try await accountValue(address: address) else {
            return nil
        }
        guard let lamportsValue = value.object?["lamports"]?.decimal,
              let lamports = Self.exactUInt64(lamportsValue),
              let dataLength = Self.accountDataLength(value),
              (0...10_485_760).contains(dataLength)
        else {
            throw invalidResponse("account_state")
        }
        return SendSolanaAccountState(
            lamports: lamports,
            dataLength: dataLength
        )
    }

    func tokenBalance(address: String) async throws -> UInt64 {
        let result = try await call(
            method: "getTokenAccountBalance",
            params: [
                .string(address),
                .object(["commitment": .string("confirmed")])
            ]
        )
        guard let amount = result.object?["value"]?
            .object?["amount"]?.string,
            let balance = UInt64(amount)
        else {
            throw invalidResponse("token_balance")
        }
        return balance
    }

    func tokenProgram(mint: String) async throws -> TokenProgram {
        let value = try await accountValue(address: mint)
        guard let owner = value?.object?["owner"]?.string else {
            throw invalidResponse("mint_owner")
        }
        switch owner {
        case SolanaConstants.tokenProgramID:
            return .legacy
        case SolanaConstants.token2022ProgramID:
            return .token2022
        default:
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: "unsupported_token_program",
                message: WalletLocalization.string(
                    "send.submit.error.solana_token_program"
                )
            )
        }
    }

    func accountExists(address: String) async throws -> Bool {
        try await accountValue(address: address) != nil
    }

    func tokenAccountDataLength(
        address: String,
        program: TokenProgram
    ) async throws -> Int {
        guard let value = try await accountValue(address: address),
              value.object?["owner"]?.string == program.address,
              let encoded = value.object?["data"]?.array?.first?.string,
              let data = Data(base64Encoded: encoded),
              data.count >= 165,
              data.count <= 65_536
        else {
            throw invalidResponse("token_account_data")
        }
        return data.count
    }

    func minimumTokenAccountRent(dataLength: Int) async throws -> UInt64 {
        guard (165...65_536).contains(dataLength) else {
            throw invalidResponse("token_account_length")
        }
        return try await minimumBalanceForRentExemption(
            dataLength: dataLength
        )
    }

    func minimumBalanceForRentExemption(
        dataLength: Int
    ) async throws -> UInt64 {
        guard (0...10_485_760).contains(dataLength) else {
            throw invalidResponse("account_length")
        }
        let result = try await call(
            method: "getMinimumBalanceForRentExemption",
            params: [.number(Decimal(dataLength))]
        )
        guard let value = result.decimal,
              let rent = Self.exactUInt64(value)
        else {
            throw invalidResponse("account_rent")
        }
        return rent
    }

    func feeForMessage(base64Message: String) async throws -> UInt64 {
        let result = try await call(
            method: "getFeeForMessage",
            params: [
                .string(base64Message),
                .object(["commitment": .string("confirmed")])
            ]
        )
        guard let value = result.object?["value"],
              case let .number(decimal) = value,
              let fee = Self.exactUInt64(decimal)
        else {
            throw invalidResponse("message_fee")
        }
        return fee
    }

    func broadcast(base64Transaction: String) async throws -> String {
        let result = try await call(
            method: "sendTransaction",
            params: [
                .string(base64Transaction),
                .object([
                    "encoding": .string("base64"),
                    "preflightCommitment": .string("confirmed"),
                    "skipPreflight": .bool(false),
                    "maxRetries": .number(Decimal(5))
                ])
            ],
            isBroadcast: true
        )
        guard let signature = result.string else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_transaction_signature_type"
                )
        }
        guard !signature.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "empty_transaction_signature"
                )
        }
        return signature
    }

    private func accountValue(
        address: String
    ) async throws -> SolanaJSONValue? {
        let result = try await call(
            method: "getAccountInfo",
            params: [
                .string(address),
                .object([
                    "commitment": .string("confirmed"),
                    "encoding": .string("base64")
                ])
            ]
        )
        guard let value = result.object?["value"] else {
            throw invalidResponse("account_info")
        }
        if case .null = value { return nil }
        return value
    }

    private func call(
        method: String,
        params: [SolanaJSONValue],
        isBroadcast: Bool = false
    ) async throws -> SolanaJSONValue {
        requestID += 1
        let expectedID = requestID
        let requestBody = try JSONEncoder().encode(
            SendSolanaRPCRequest(
                id: expectedID,
                method: method,
                params: params
            )
        )
        let serviceID = "provider-routing.solana-jsonrpc"
        let currentSession = session
        let attempts = endpoints.enumerated().map { index, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt(endpoint: identity) {
                try await Self.perform(
                    endpoint: endpoint,
                    requestBody: requestBody,
                    expectedID: expectedID,
                    session: currentSession,
                    isBroadcast: isBroadcast
                )
            }
        }
        do {
            if isBroadcast {
                return try await AdaptiveProviderRouter.shared
                    .executeSubmission(
                        serviceID: serviceID,
                        attempts: attempts,
                        timeoutSeconds: 15,
                        isReliabilityFailure: Self.isReliabilityFailure
                    )
            }
            return try await AdaptiveProviderRouter.shared.executeRead(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 8,
                shouldFallback: Self.isReliabilityFailure
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendTransactionSubmissionError {
            throw error
        } catch {
            if isBroadcast {
                let code = SendTransactionSubmissionError
                    .sanitizedErrorType(error)
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SolanaConstants.networkID,
                        code: code
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                message: WalletLocalization.string(
                    "send.submit.error.provider_transport"
                )
            )
        }
    }

    private nonisolated static func perform(
        endpoint: URL,
        requestBody: Data,
        expectedID: Int,
        session: URLSession,
        isBroadcast: Bool
    ) async throws -> SolanaJSONValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = requestBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isBroadcast {
                let code = SendTransactionSubmissionError
                    .sanitizedErrorType(error)
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SolanaConstants.networkID,
                        code: code
                    )
            }
            throw error
        }
        if Task.isCancelled {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SolanaConstants.networkID,
                        code: "cancelled_after_response"
                    )
            }
            try Task.checkCancellation()
        }
        guard let http = response as? HTTPURLResponse else {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SolanaConstants.networkID,
                        code: "non_http_response"
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: "invalid_non_http",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let envelope = try? JSONDecoder().decode(
            SendSolanaRPCResponse.self,
            from: data
        )
        if isBroadcast {
            return try Self.broadcastResult(
                envelope: envelope,
                expectedID: expectedID,
                statusCode: http.statusCode
            )
        }
        if let error = envelope?.error {
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: "rpc_\(error.code)",
                message: SendTransactionSubmissionError
                    .sanitizedMessage(error.message)
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: "http_\(http.statusCode)",
                message: SendTransactionSubmissionError
                    .sanitizedMessage(
                        String(data: data, encoding: .utf8) ?? ""
                    )
            )
        }
        guard let envelope,
              envelope.id == expectedID,
              let result = envelope.result
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: SolanaConstants.networkID,
                code: "invalid_envelope",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return result
    }

    private nonisolated static func isReliabilityFailure(
        _ error: Error
    ) -> Bool {
        if ProviderReliabilityClassification
            .isRetryableTransport(error) {
            return true
        }
        guard let submissionError = error
                as? SendTransactionSubmissionError
        else { return false }
        switch submissionError {
        case let .provider(_, code, message):
            if code == "invalid_non_http" { return true }
            if code.hasPrefix("http_"),
               let status = Int(code.dropFirst(5)) {
                return ProviderReliabilityClassification
                    .isRetryableHTTPStatus(status)
            }
            if code.hasPrefix("rpc_"),
               let rpcCode = Int(code.dropFirst(4)) {
                return ProviderReliabilityClassification
                    .isRetryableJSONRPCError(
                        code: rpcCode,
                        message: message
                    )
            }
            return false
        case .broadcastOutcomeUnknown:
            return true
        default:
            return false
        }
    }

    private static func broadcastResult(
        envelope: SendSolanaRPCResponse?,
        expectedID: Int,
        statusCode: Int
    ) throws -> SolanaJSONValue {
        guard let envelope,
              envelope.id == expectedID
        else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_envelope"
                )
        }
        if let error = envelope.error {
            guard envelope.result == nil else {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SolanaConstants.networkID,
                        code: "ambiguous_envelope"
                    )
            }
            let code = "rpc_\(error.code)"
            if SendSolanaSubmissionErrorClassifier
                .isDefinitiveRPCRejection(code: error.code) {
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: code,
                    message: SendTransactionSubmissionError
                        .sanitizedMessage(error.message)
                )
            }
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: SolanaConstants.networkID,
                code: code
            )
        }
        guard (200..<300).contains(statusCode) else {
            let code = "http_\(statusCode)"
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: code
                )
        }
        guard let result = envelope.result else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_envelope"
                )
        }
        return result
    }

    private func invalidResponse(
        _ code: String
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: SolanaConstants.networkID,
            code: "invalid_\(code)",
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }

    private static func exactUInt64(_ decimal: Decimal) -> UInt64? {
        let text = NSDecimalNumber(decimal: decimal).stringValue
        guard !text.contains("e"),
              !text.contains("E"),
              let value = UInt64(text),
              Decimal(string: text) == decimal
        else {
            return nil
        }
        return value
    }

    private static func accountDataLength(
        _ value: SolanaJSONValue
    ) -> Int? {
        if let spaceValue = value.object?["space"]?.decimal,
           let space = exactUInt64(spaceValue),
           space <= UInt64(Int.max) {
            return Int(space)
        }
        guard let encoded = value.object?["data"]?.array?.first?.string,
              let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return data.count
    }

    private nonisolated static func defaultEndpoints() -> [URL] {
        var values: [URL] = []
        if let configuration = try? AnkrConfiguration.runtime(),
           let configured = try? configuration.solanaJSONRPCEndpoint {
            values.append(configured)
        }
        values.append(
            URL(string: "https://solana-rpc.publicnode.com")!
        )
        values.append(
            URL(string: "https://api.mainnet-beta.solana.com")!
        )
        return values
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

enum SendSolanaSubmissionErrorClassifier {
    static func isDefinitiveRPCRejection(code: Int) -> Bool {
        [
            -32_700,
            -32_600,
            -32_601,
            -32_602,
            -32_002,
            -32_003,
            -32_013,
            -32_015
        ].contains(code)
    }

    static func isAlreadyProcessedMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("transaction has already been processed")
            || normalized.contains("transaction was already processed")
            || normalized.contains("transaction already processed")
    }
}
