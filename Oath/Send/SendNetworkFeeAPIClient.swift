import Foundation

enum SendNetworkFeeAPIError: Error, Hashable, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case invalidNetwork
    case transport(String)
    case invalidHTTPResponse
    case server(status: Int, code: String)
    case invalidResponse(String)

    var diagnosticCode: String {
        switch self {
        case .missingConfiguration:
            "configuration_missing"
        case .invalidConfiguration:
            "configuration_invalid"
        case .invalidNetwork:
            "network_invalid"
        case let .transport(code):
            "transport_\(code)"
        case .invalidHTTPResponse:
            "response_not_http"
        case let .server(status, code):
            "server_\(status)_\(code)"
        case let .invalidResponse(code):
            "response_invalid_\(code)"
        }
    }

    var localizedMessage: String {
        switch self {
        case .missingConfiguration, .invalidConfiguration:
            return WalletLocalization.string(
                "send.network_fee.error.service_configuration"
            )
        case .invalidNetwork:
            return WalletLocalization.string(
                "send.network_fee.error.unsupported_network"
            )
        case .transport:
            return WalletLocalization.string(
                "send.network_fee.error.connection"
            )
        case .invalidHTTPResponse, .invalidResponse:
            return WalletLocalization.string(
                "send.network_fee.error.invalid_response"
            )
        case let .server(status, code):
            return EnglishNumbers.localized(
                "send.network_fee.error.server",
                status,
                code
            )
        }
    }
}

struct SendNetworkFeeAPIClient: Sendable {
    static let liveQuoteTimeout: Duration = .seconds(3)
    static let builtInDefaultProvider = "built_in_default"

    static let directQuoteNetworkIDs: Set<String> = [
        SuiConstants.networkID,
        XRPConstants.networkID,
        NEARConstants.networkID,
        AptosConstants.networkID,
        StellarConstants.networkID
    ]

    static let workerQuoteNetworkIDs: Set<String> = [
        "eth", "bsc", "arbitrum", "base", "polygon", "optimism",
        "avalanche", "gnosis", "linea", "scroll", "taiko", "telos",
        "xlayer", "arc", "bitcoin", "bitcoin_cash", "litecoin", "dogecoin",
        SolanaConstants.networkID, TronConstants.networkID,
        TONConstants.networkID
    ]

    static let supportedQuoteNetworkIDs = directQuoteNetworkIDs
        .union(workerQuoteNetworkIDs)

    private let baseURL: URL
    private let decoder: JSONDecoder
    private let requestExecutor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: URL, session: URLSession? = nil) throws {
        guard
            baseURL.scheme?.lowercased() == "https",
            baseURL.user == nil,
            baseURL.password == nil,
            baseURL.query == nil,
            baseURL.fragment == nil
        else {
            throw SendNetworkFeeAPIError.invalidConfiguration
        }
        self.baseURL = baseURL
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 16
            resolvedSession = URLSession(configuration: configuration)
        }
        requestExecutor = { request in
            try await resolvedSession.data(for: request)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    init(
        baseURL: URL,
        requestExecutor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse)
    ) throws {
        guard
            baseURL.scheme?.lowercased() == "https",
            baseURL.user == nil,
            baseURL.password == nil,
            baseURL.query == nil,
            baseURL.fragment == nil
        else {
            throw SendNetworkFeeAPIError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.requestExecutor = requestExecutor
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    static func configured() throws -> SendNetworkFeeAPIClient {
        guard
            let value = Bundle.main.object(
                forInfoDictionaryKey: "NotificationServiceBaseURL"
            ) as? String,
            !value.isEmpty,
            !value.contains("$("),
            let url = URL(string: value)
        else {
            throw SendNetworkFeeAPIError.missingConfiguration
        }
        return try SendNetworkFeeAPIClient(baseURL: url)
    }

    static func quote(
        for networkID: String
    ) async throws -> SendNetworkFeeQuote {
        try await quoteWithFallback(
            for: networkID,
            timeout: liveQuoteTimeout
        ) {
            try await liveQuote(for: networkID)
        }
    }

    static func defaultQuote(
        for networkID: String,
        now: Date = Date()
    ) throws -> SendNetworkFeeQuote {
        guard supportedQuoteNetworkIDs.contains(networkID),
              let values = SendNetworkFeeDefaultCatalog.values[networkID]
        else {
            throw SendNetworkFeeAPIError.invalidNetwork
        }
        let tiers = [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ].map {
            SendNetworkFeeTier(
                preset: $0,
                model: values.model,
                primaryValue: values.primaryValue,
                secondaryValue: values.secondaryValue
            )
        }
        return SendNetworkFeeQuote(
            networkID: networkID,
            provider: builtInDefaultProvider,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(60),
            tiers: tiers,
            tronParameters: networkID == TronConstants.networkID ? .defaults : nil
        )
    }

    static func quoteWithFallback(
        for networkID: String,
        timeout: Duration,
        liveLoader: @escaping @Sendable () async throws
            -> SendNetworkFeeQuote
    ) async throws -> SendNetworkFeeQuote {
        let fallback = try defaultQuote(for: networkID)
        do {
            let quote = try await quoteBeforeDeadline(
                timeout: timeout,
                operation: liveLoader
            )
            guard isValid(quote, expectedNetworkID: networkID) else {
                throw SendNetworkFeeAPIError.invalidResponse("metadata")
            }
            return quote
        } catch is CancellationError {
            guard !Task.isCancelled else { throw CancellationError() }
            return fallback
        } catch {
            return fallback
        }
    }

    private static func liveQuote(
        for networkID: String
    ) async throws -> SendNetworkFeeQuote {
        if networkID == TronConstants.networkID {
            // Include account-activation prices in the same durable sample.
            // Review and signing must not call getchainparameters again.
            let parameters = try await SendTronAPIClient().protocolParameters()
            let now = Date()
            return SendNetworkFeeQuote(networkID: networkID, provider: "trongrid",
                fetchedAt: now, expiresAt: now.addingTimeInterval(60),
                tiers: [SendNetworkFeePreset.fastest, .standard, .economy].map {
                    SendNetworkFeeTier(preset: $0, model: .tronProtocol,
                        primaryValue: String(parameters.energyPrice), secondaryValue: String(parameters.bandwidthPrice))
                }, tronParameters: parameters)
        }
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            do {
                return try await SendBitcoinFamilyHTTPAPIClient.quote(
                    for: chain
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The app's HTTPS worker is an independent provider fallback.
                // quoteWithFallback supplies the built-in rate if both fail.
                return try await configured().quote(for: networkID)
            }
        }
        if directQuoteNetworkIDs.contains(networkID) {
            return try await retryingQuote {
                try await directQuote(for: networkID)
            }
        }
        return try await configured().quote(for: networkID)
    }

    private static func quoteBeforeDeadline(
        timeout: Duration,
        operation: @escaping @Sendable () async throws
            -> SendNetworkFeeQuote
    ) async throws -> SendNetworkFeeQuote {
        precondition(timeout > .zero)
        return try await withThrowingTaskGroup(
            of: SendNetworkFeeQuote.self
        ) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SendNetworkFeeDeadlineError()
            }
            defer { group.cancelAll() }
            guard let quote = try await group.next() else {
                throw SendNetworkFeeDeadlineError()
            }
            return quote
        }
    }

    func quote(for networkID: String) async throws
        -> SendNetworkFeeQuote {
        guard Self.workerQuoteNetworkIDs.contains(networkID) else {
            throw SendNetworkFeeAPIError.invalidNetwork
        }
        return try await Self.retryingQuote {
            try await requestQuote(for: networkID)
        }
    }

    static func retryingQuote(
        maximumAttempts: Int = 2,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        operation: @escaping @Sendable () async throws
            -> SendNetworkFeeQuote
    ) async throws -> SendNetworkFeeQuote {
        precondition(maximumAttempts > 0)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard attempt < maximumAttempts,
                      isRetryable(error)
                else {
                    throw error
                }
                try await sleeper(
                    .milliseconds(Int64(250 * attempt))
                )
                attempt += 1
            }
        }
    }

    private func requestQuote(for networkID: String) async throws
        -> SendNetworkFeeQuote {
        guard
            !networkID.isEmpty,
            networkID.utf8.count <= 64,
            networkID.allSatisfy({
                ($0 >= "a" && $0 <= "z")
                    || ($0 >= "0" && $0 <= "9")
                    || $0 == "_"
            })
        else {
            throw SendNetworkFeeAPIError.invalidNetwork
        }
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("network-fees")
            .appendingPathComponent(networkID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SendNetworkFeeAPIError.invalidHTTPResponse
        }
        guard http.statusCode == 200 else {
            throw SendNetworkFeeAPIError.server(
                status: http.statusCode,
                code: Self.serverErrorCode(data)
            )
        }
        let envelope: SendNetworkFeeQuoteEnvelope
        do {
            envelope = try decoder.decode(
                SendNetworkFeeQuoteEnvelope.self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                Self.errorTypeCode(error)
            )
        }
        guard Self.isValid(envelope.quote, expectedNetworkID: networkID) else {
            throw SendNetworkFeeAPIError.invalidResponse("metadata")
        }
        return envelope.quote
    }

    private static func directQuote(
        for networkID: String
    ) async throws -> SendNetworkFeeQuote {
        switch networkID {
        case SuiConstants.networkID:
            return try await suiQuote()
        case XRPConstants.networkID:
            return try await xrpQuote()
        case NEARConstants.networkID:
            return try await nearQuote()
        case AptosConstants.networkID:
            return try await aptosQuote()
        case StellarConstants.networkID:
            return try await stellarQuote()
        default:
            throw SendNetworkFeeAPIError.invalidNetwork
        }
    }

    private static func suiQuote() async throws -> SendNetworkFeeQuote {
        let referenceGasPrice: UInt64
        do {
            referenceGasPrice = try await SuiAPIClient.shared
                .referenceGasPrice()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SuiProviderError {
            throw SendNetworkFeeAPIError.invalidResponse(
                error.diagnosticDescription
            )
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        let fetchedAt = Date()
        let tiers = [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ].map {
            SendNetworkFeeTier(
                preset: $0,
                model: .suiProtocol,
                primaryValue: String(SuiConstants.defaultGasBudget),
                secondaryValue: String(referenceGasPrice)
            )
        }
        return SendNetworkFeeQuote(
            networkID: SuiConstants.networkID,
            provider: "ankr-sui-graphql",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30),
            tiers: tiers
        )
    }

    private static func xrpQuote() async throws -> SendNetworkFeeQuote {
        let feeDrops: UInt64
        do {
            feeDrops = try await XRPAPIClient.shared.currentFeeDrops()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as XRPProviderError {
            throw SendNetworkFeeAPIError.invalidResponse(
                error.diagnosticDescription
            )
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        let fetchedAt = Date()
        let tiers = [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ].map {
            SendNetworkFeeTier(
                preset: $0,
                model: .xrpProtocol,
                primaryValue: String(max(feeDrops, 10)),
                secondaryValue: nil
            )
        }
        return SendNetworkFeeQuote(
            networkID: XRPConstants.networkID,
            provider: "ankr-xrp-jsonrpc",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30),
            tiers: tiers
        )
    }

    private static func nearQuote() async throws -> SendNetworkFeeQuote {
        let gasPrice: String
        do {
            gasPrice = try await NEARAPIClient.shared.gasPrice()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NEARProviderError {
            throw SendNetworkFeeAPIError.invalidResponse(
                error.diagnosticDescription
            )
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        let reserve: String
        do {
            reserve = try SendAtomicAmount.multiply(
                gasPrice,
                by: NEARConstants.maximumTransactionGas
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "near_fee_out_of_range"
            )
        }
        let fetchedAt = Date()
        let tiers = [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ].map {
            SendNetworkFeeTier(
                preset: $0,
                model: .nearProtocol,
                primaryValue: reserve,
                secondaryValue: gasPrice
            )
        }
        return SendNetworkFeeQuote(
            networkID: NEARConstants.networkID,
            provider: "ankr-near-jsonrpc",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30),
            tiers: tiers
        )
    }

    private static func aptosQuote() async throws -> SendNetworkFeeQuote {
        let estimate: AptosGasEstimate
        do {
            estimate = try await AptosAPIClient.shared.gasEstimate()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AptosProviderError {
            throw SendNetworkFeeAPIError.invalidResponse(
                error.diagnosticDescription
            )
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        let fetchedAt = Date()
        let prices: [(SendNetworkFeePreset, UInt64)] = [
            (.fastest, estimate.prioritized),
            (.standard, estimate.standard),
            (.economy, estimate.deprioritized)
        ]
        let tiers = try prices.map { preset, price in
            SendNetworkFeeTier(
                preset: preset,
                model: .aptosProtocol,
                primaryValue: try SendAtomicAmount.multiply(
                    String(price),
                    by: AptosConstants.defaultMaximumGasAmount
                ),
                secondaryValue: String(price)
            )
        }
        return SendNetworkFeeQuote(
            networkID: AptosConstants.networkID,
            provider: "aptos-mainnet-rest",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30),
            tiers: tiers
        )
    }

    private static func stellarQuote() async throws -> SendNetworkFeeQuote {
        let state: StellarNetworkState
        do {
            state = try await StellarAPIClient.shared.networkState()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StellarProviderError {
            throw SendNetworkFeeAPIError.invalidResponse(
                error.diagnosticDescription
            )
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        let fee = max(
            state.recommendedFeeStroops,
            StellarConstants.minimumFeeStroops
        )
        guard fee > 0 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "stellar_fee_out_of_range"
            )
        }
        let fetchedAt = Date()
        let tiers = [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ].map {
            SendNetworkFeeTier(
                preset: $0,
                model: .stellarProtocol,
                primaryValue: String(fee),
                secondaryValue: nil
            )
        }
        return SendNetworkFeeQuote(
            networkID: StellarConstants.networkID,
            provider: "ankr-stellar-horizon",
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(30),
            tiers: tiers
        )
    }

    static func isValid(
        _ quote: SendNetworkFeeQuote,
        expectedNetworkID: String
    ) -> Bool {
        let now = Date()
        guard
            isValidForSessionReuse(
                quote,
                expectedNetworkID: expectedNetworkID
            ),
            quote.fetchedAt <= now.addingTimeInterval(60),
            quote.expiresAt > now
        else {
            return false
        }
        return true
    }

    /// Validate the full mainnet response shape independently of sample age.
    /// The database cache policy bounds reuse; a reviewed transaction retains
    /// its approved rates as the user navigates through Send.
    static func isValidForSessionReuse(
        _ quote: SendNetworkFeeQuote,
        expectedNetworkID: String
    ) -> Bool {
        guard
            quote.networkID == expectedNetworkID,
            !quote.provider.isEmpty,
            quote.provider.utf8.count <= 64,
            quote.fetchedAt <= quote.expiresAt,
            quote.expiresAt.timeIntervalSince(quote.fetchedAt) <= 120,
            quote.tiers.count == 3,
            Set(quote.tiers.map(\.preset))
                == Set([.fastest, .standard, .economy])
        else {
            return false
        }
        if let parameters = quote.tronParameters {
            guard expectedNetworkID == TronConstants.networkID, parameters.isValid,
                  quote.tiers.allSatisfy({
                      $0.primaryValue == String(parameters.energyPrice)
                        && $0.secondaryValue == String(parameters.bandwidthPrice)
                  }) else { return false }
        }
        return quote.tiers.allSatisfy {
            isValid($0, expectedNetworkID: expectedNetworkID)
        }
    }

    private static func isValid(
        _ tier: SendNetworkFeeTier,
        expectedNetworkID: String
    ) -> Bool {
        SendNetworkFeeValidation.isValid(tier, networkID: expectedNetworkID)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let feeError = error as? SendNetworkFeeAPIError else {
            return true
        }
        switch feeError {
        case .missingConfiguration, .invalidConfiguration, .invalidNetwork:
            return false
        case .transport, .invalidHTTPResponse, .invalidResponse:
            return true
        case let .server(status, _):
            return status == 408 || status == 425 || status == 429
                || (500...599).contains(status)
        }
    }

    private static func serverErrorCode(_ data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let error = object["error"] as? [String: Any],
            let code = error["code"] as? String
        else {
            return "unknown"
        }
        return sanitizedCode(code)
    }

    private static func errorTypeCode(_ error: Error) -> String {
        sanitizedCode(String(reflecting: type(of: error)))
    }

    private static func sanitizedCode(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars).prefix(80).description
    }
}

private struct SendNetworkFeeDeadlineError: Error, Sendable {}

private struct SendNetworkFeeDefaultValues: Sendable {
    let model: SendNetworkFeeQuoteModel
    let primaryValue: String
    let secondaryValue: String?

    static func eip1559(
        maximumFeeWei: String,
        priorityFeeWei: String
    ) -> SendNetworkFeeDefaultValues {
        SendNetworkFeeDefaultValues(
            model: .evmEIP1559,
            primaryValue: maximumFeeWei,
            secondaryValue: priorityFeeWei
        )
    }

    static func protocolFee(
        model: SendNetworkFeeQuoteModel,
        primaryValue: String,
        secondaryValue: String? = nil
    ) -> SendNetworkFeeDefaultValues {
        SendNetworkFeeDefaultValues(
            model: model,
            primaryValue: primaryValue,
            secondaryValue: secondaryValue
        )
    }
}

private enum SendNetworkFeeDefaultCatalog {
    static let values: [String: SendNetworkFeeDefaultValues] = [
        "eth": .eip1559(
            maximumFeeWei: "30000000000",
            priorityFeeWei: "2000000000"
        ),
        "bsc": .eip1559(
            maximumFeeWei: "3000000000",
            priorityFeeWei: "100000000"
        ),
        "arbitrum": .eip1559(
            maximumFeeWei: "200000000",
            priorityFeeWei: "10000000"
        ),
        "base": .eip1559(
            maximumFeeWei: "200000000",
            priorityFeeWei: "20000000"
        ),
        "polygon": .eip1559(
            maximumFeeWei: "1000000000000",
            priorityFeeWei: "350000000000"
        ),
        "optimism": .eip1559(
            maximumFeeWei: "20000000",
            priorityFeeWei: "1000000"
        ),
        "avalanche": .eip1559(
            maximumFeeWei: "2000000000",
            priorityFeeWei: "1000000000"
        ),
        "gnosis": .eip1559(
            maximumFeeWei: "1000000",
            priorityFeeWei: "1000"
        ),
        "linea": .eip1559(
            maximumFeeWei: "200000000",
            priorityFeeWei: "100000000"
        ),
        "scroll": .eip1559(
            maximumFeeWei: "20000000",
            priorityFeeWei: "1000000"
        ),
        "taiko": .eip1559(
            maximumFeeWei: "200000000",
            priorityFeeWei: "10000000"
        ),
        "telos": .eip1559(
            maximumFeeWei: "6000000000000",
            priorityFeeWei: "5500000000000"
        ),
        "xlayer": .eip1559(
            maximumFeeWei: "200000000",
            priorityFeeWei: "10000000"
        ),
        // Arc drops transactions whose maxFeePerGas is under its 20 gwei
        // base-fee floor, so the offline default stays well above it.
        "arc": .eip1559(
            maximumFeeWei: "40000000000",
            priorityFeeWei: "1000000000"
        ),
        "bitcoin": .protocolFee(
            model: .utxoPerVByte,
            primaryValue: String(SendBitcoinTransactionPolicy.minimumAutomaticFeeRate)
        ),
        "bitcoin_cash": .protocolFee(
            model: .utxoPerVByte,
            primaryValue: "1"
        ),
        "litecoin": .protocolFee(
            model: .utxoPerVByte,
            primaryValue: "2"
        ),
        "dogecoin": .protocolFee(
            model: .utxoPerVByte,
            primaryValue: "1000"
        ),
        SolanaConstants.networkID: .protocolFee(
            model: .solanaPriority,
            primaryValue: "0"
        ),
        TronConstants.networkID: .protocolFee(
            model: .tronProtocol,
            primaryValue: "100",
            secondaryValue: "1000"
        ),
        TONConstants.networkID: .protocolFee(
            model: .tonProtocol,
            primaryValue: "50000000",
            secondaryValue: "100000000"
        ),
        SuiConstants.networkID: .protocolFee(
            model: .suiProtocol,
            primaryValue: String(SuiConstants.defaultGasBudget),
            secondaryValue: "1000"
        ),
        XRPConstants.networkID: .protocolFee(
            model: .xrpProtocol,
            primaryValue: "10"
        ),
        NEARConstants.networkID: .protocolFee(
            model: .nearProtocol,
            primaryValue: "10000000000000000000000",
            secondaryValue: "100000000"
        ),
        AptosConstants.networkID: .protocolFee(
            model: .aptosProtocol,
            primaryValue: "2000000",
            secondaryValue: "100"
        ),
        StellarConstants.networkID: .protocolFee(
            model: .stellarProtocol,
            primaryValue: String(StellarConstants.minimumFeeStroops)
        )
    ]
}
