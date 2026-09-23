import Foundation
import GRDB
import WalletCore

enum SolanaTokenEligibilityReason: String, Sendable {
    case eligible
    case unavailable
    case unverified
    case noLiquidity = "no_liquidity"
    case suspicious
    case denylisted
}

struct SolanaTokenEligibility: Sendable, Equatable {
    let mint: String
    let name: String?
    let symbol: String?
    let decimals: Int?
    let isVerified: Bool
    let liquidityUSD: Decimal?
    let isSuspicious: Bool
    let reason: SolanaTokenEligibilityReason
    let provider: String
    let observedAt: Double
    let expiresAt: Double

    var isEligible: Bool {
        reason == .eligible
    }

    static func unavailable(
        mint: String,
        now: Double,
        lifetime: TimeInterval
    ) -> Self {
        Self(
            mint: mint,
            name: nil,
            symbol: nil,
            decimals: nil,
            isVerified: false,
            liquidityUSD: nil,
            isSuspicious: false,
            reason: .unavailable,
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: now,
            expiresAt: now + lifetime
        )
    }
}

enum SolanaTokenEligibilityPolicy {
    static func reason(
        isVerified: Bool,
        liquidityUSD: Decimal?,
        isSuspicious: Bool
    ) -> SolanaTokenEligibilityReason {
        if isSuspicious {
            return .suspicious
        }
        guard isVerified else {
            return .unverified
        }
        guard let liquidityUSD, liquidityUSD > 0 else {
            return .noLiquidity
        }
        return .eligible
    }

    static func enrichedSnapshot(
        _ snapshot: SolanaWalletSnapshot,
        eligibilityByMint: [String: SolanaTokenEligibility]
    ) throws -> SolanaWalletSnapshot {
        let addressSnapshots = snapshot.addressSnapshots.map {
            addressSnapshot in
            SolanaAddressSnapshot(
                material: addressSnapshot.material,
                solBalance: addressSnapshot.solBalance,
                solAtomicBalance: addressSnapshot.solAtomicBalance,
                tokenBalances: addressSnapshot.tokenBalances.map {
                    enrichedToken(
                        $0,
                        eligibilityByMint: eligibilityByMint
                    )
                },
                balanceAuthority: addressSnapshot.balanceAuthority
            )
        }
        let history = snapshot.history.map { item in
            guard let mint = item.mint else {
                return item
            }
            let eligibility = eligibilityByMint[mint]
            let hasMatchingDecimals =
                eligibility?.decimals == item.decimals
            return SolanaHistoryItem(
                signature: item.signature,
                sourceAddress: item.sourceAddress,
                slot: item.slot,
                timestamp: item.timestamp,
                failed: item.failed,
                from: item.from,
                to: item.to,
                mint: mint,
                symbol: hasMatchingDecimals
                    ? nonempty(eligibility?.symbol) ?? item.symbol
                    : item.symbol,
                decimals: item.decimals,
                amount: item.amount,
                atomicAmount: item.atomicAmount,
                fee: item.fee
            )
        }
        return try SolanaWalletSnapshot(
            accounts: snapshot.accounts,
            addressSnapshots: addressSnapshots,
            history: history,
            historyCursors: snapshot.historyCursors
        )
    }

    private static func enrichedToken(
        _ token: SolanaTokenBalance,
        eligibilityByMint: [String: SolanaTokenEligibility]
    ) -> SolanaTokenBalance {
        let eligibility = eligibilityByMint[token.mint]
        let hasMatchingDecimals = eligibility?.decimals == token.decimals
        return SolanaTokenBalance(
            mint: token.mint,
            tokenAccountAddresses: token.tokenAccountAddresses,
            name: hasMatchingDecimals
                ? nonempty(eligibility?.name) ?? token.name
                : token.name,
            symbol: hasMatchingDecimals
                ? nonempty(eligibility?.symbol) ?? token.symbol
                : token.symbol,
            decimals: token.decimals,
            amount: token.amount,
            atomicAmount: token.atomicAmount,
            catalogRank: token.catalogRank
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

protocol SolanaTokenEligibilityFetching: Sendable {
    func fetch(
        mints: [String]
    ) async throws -> [String: SolanaTokenEligibility]
}

enum SolanaTokenEligibilityError: Error, Sendable {
    case invalidResponse
    case httpFailure(statusCode: Int, providerMessage: String?)
    case allEndpointsFailed(lastFailure: String)

    var diagnosticDescription: String {
        switch self {
        case .invalidResponse:
            return "jupiter_tokens_invalid_http_response"
        case let .httpFailure(statusCode, message):
            if let message, !message.isEmpty {
                return "jupiter_tokens_http_status=\(statusCode) provider_message=\(message)"
            }
            return "jupiter_tokens_http_status=\(statusCode)"
        case let .allEndpointsFailed(lastFailure):
            return "jupiter_tokens_all_endpoints_failed last_failure=\(lastFailure)"
        }
    }
}

enum SolanaCustomTokenLookupError: Error, Sendable {
    case unsupportedNetwork
    case invalidMint
    case tokenNotFound
    case invalidMintAccount
    case invalidMetadata
    case unsafeToken

    var diagnosticDescription: String {
        switch self {
        case .unsupportedNetwork: "solana_custom_token_unsupported_network"
        case .invalidMint: "solana_custom_token_invalid_mint"
        case .tokenNotFound: "solana_custom_token_not_found"
        case .invalidMintAccount: "solana_custom_token_invalid_mint_account"
        case .invalidMetadata: "solana_custom_token_invalid_metadata"
        case .unsafeToken: "solana_custom_token_blocked_by_safety_policy"
        }
    }
}

actor SolanaTokenEligibilityClient: SolanaTokenEligibilityFetching {
    static let shared = SolanaTokenEligibilityClient()
    static let providerIdentifier = "jupiter-tokens-v2"

    private static let productionEndpoints = [
        URL(string: "https://lite-api.jup.ag/tokens/v2/search")!,
        URL(string: "https://api.jup.ag/tokens/v2/search")!
    ]
    private static let maximumMintsPerRequest = 100
    private static let positiveLifetime: TimeInterval = 60 * 60

    typealias RequestExecutor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)
    typealias AccountInfoLoader = @Sendable (String) async throws
        -> SolanaJSONValue

    private let endpoints: [URL]
    private let requestExecutor: RequestExecutor
    private let accountInfoLoader: AccountInfoLoader

    init(
        endpoints: [URL] = productionEndpoints,
        session: URLSession? = nil,
        accountInfoLoader: AccountInfoLoader? = nil
    ) {
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            resolvedSession = URLSession(configuration: configuration)
        }
        self.endpoints = endpoints
        requestExecutor = { request in
            try await resolvedSession.data(for: request)
        }
        self.accountInfoLoader = accountInfoLoader ?? { mint in
            try await SolanaRPCTransport.shared.call(
                method: "getAccountInfo",
                params: [
                    .string(mint),
                    .object([
                        "encoding": .string("jsonParsed"),
                        "commitment": .string("confirmed")
                    ])
                ]
            )
        }
    }

    init(
        endpoints: [URL],
        requestExecutor: @escaping RequestExecutor,
        accountInfoLoader: AccountInfoLoader? = nil
    ) {
        self.endpoints = endpoints
        self.requestExecutor = requestExecutor
        self.accountInfoLoader = accountInfoLoader ?? { mint in
            try await SolanaRPCTransport.shared.call(
                method: "getAccountInfo",
                params: [
                    .string(mint),
                    .object([
                        "encoding": .string("jsonParsed"),
                        "commitment": .string("confirmed")
                    ])
                ]
            )
        }
    }

    func lookupToken(
        network: ReceiveNetwork,
        mint: String
    ) async throws -> CustomSolanaToken {
        guard network.id == SolanaConstants.networkID else {
            throw SolanaCustomTokenLookupError.unsupportedNetwork
        }
        guard Self.isValidMint(mint) else {
            throw SolanaCustomTokenLookupError.invalidMint
        }
        guard !TokenSafetyPolicy.isHardDenied(
            networkID: network.id,
            contractAddress: mint
        ) else {
            throw SolanaCustomTokenLookupError.unsafeToken
        }

        async let accountInfo = accountInfoLoader(mint)
        let metadataByMint = try await fetch(mints: [mint])
        let accountDecimals = try Self.validatedMintDecimals(
            from: try await accountInfo
        )
        guard let eligibility = metadataByMint[mint] else {
            throw SolanaCustomTokenLookupError.tokenNotFound
        }
        guard !eligibility.isSuspicious,
              eligibility.reason != .denylisted
        else {
            throw SolanaCustomTokenLookupError.unsafeToken
        }
        guard
            let name = Self.metadataText(
                eligibility.name,
                maximumLength: 80
            ),
            let symbol = Self.metadataText(
                eligibility.symbol,
                maximumLength: 24
            ),
            eligibility.decimals == accountDecimals
        else {
            throw SolanaCustomTokenLookupError.invalidMetadata
        }
        let logoSource = ReceiveAssetCatalog.variant(
            networkID: network.id,
            contractAddress: mint
        )?.logoSource ?? .unavailable
        return CustomSolanaToken(
            network: network,
            mintAddress: mint,
            name: name,
            symbol: symbol,
            decimals: accountDecimals,
            logoSource: logoSource,
            eligibility: eligibility
        )
    }

    func fetch(
        mints: [String]
    ) async throws -> [String: SolanaTokenEligibility] {
        let uniqueMints = Array(Set(mints.filter(Self.isValidMint))).sorted()
        guard !uniqueMints.isEmpty else {
            return [:]
        }
        let chunks = stride(
            from: 0,
            to: uniqueMints.count,
            by: Self.maximumMintsPerRequest
        ).map { offset in
            Array(
                uniqueMints[
                    offset..<min(
                        offset + Self.maximumMintsPerRequest,
                        uniqueMints.count
                    )
                ]
            )
        }
        let endpoints = self.endpoints
        let requestExecutor = self.requestExecutor
        let fetched = try await withThrowingTaskGroup(
            of: [SolanaTokenEligibility].self
        ) { group in
            for chunk in chunks {
                group.addTask {
                    try await Self.fetchChunk(
                        chunk,
                        endpoints: endpoints,
                        requestExecutor: requestExecutor
                    )
                }
            }
            var result: [SolanaTokenEligibility] = []
            for try await chunk in group {
                result.append(contentsOf: chunk)
            }
            return result
        }
        let requestedMints = Set(uniqueMints)
        return Dictionary(
            fetched.compactMap { eligibility in
                requestedMints.contains(eligibility.mint)
                    ? (eligibility.mint, eligibility)
                    : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func fetchChunk(
        _ mints: [String],
        endpoints: [URL],
        requestExecutor: @escaping RequestExecutor
    ) async throws -> [SolanaTokenEligibility] {
        let serviceID = "solana_jupiter_token_read"
        let attempts = endpoints.enumerated().map { index, endpoint in
            let providerEndpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt(endpoint: providerEndpoint) {
                let request = try request(
                    endpoint: endpoint,
                    mints: mints
                )
                let (data, response) = try await requestExecutor(request)
                guard let http = response as? HTTPURLResponse else {
                    throw SolanaTokenEligibilityError.invalidResponse
                }
                guard 200..<300 ~= http.statusCode else {
                    throw SolanaTokenEligibilityError.httpFailure(
                        statusCode: http.statusCode,
                        providerMessage: providerMessage(from: data)
                    )
                }
                let descriptors = try JSONDecoder().decode(
                    [JupiterTokenDescriptor].self,
                    from: data
                )
                let now = Date().timeIntervalSince1970
                return descriptors.map {
                    $0.eligibility(
                        now: now,
                        lifetime: positiveLifetime
                    )
                }
            }
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        switch error {
        case SolanaTokenEligibilityError.invalidResponse:
            return true
        case let SolanaTokenEligibilityError.httpFailure(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        default:
            return false
        }
    }

    private static func request(
        endpoint: URL,
        mints: [String]
    ) throws -> URLRequest {
        guard
            var components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(
                name: "query",
                value: mints.joined(separator: ",")
            )
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func providerMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            return (object["message"] as? String)
                ?? (object["error"] as? String)
        }
        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        return String(text.prefix(200))
    }

    nonisolated static func isValidMint(_ mint: String) -> Bool {
        CoinType.solana.validate(address: mint)
    }

    nonisolated static func validatedMintDecimals(
        from result: SolanaJSONValue
    ) throws -> Int {
        guard
            let value = result.object?["value"]?.object,
            let owner = value["owner"]?.string,
            owner == SolanaConstants.tokenProgramID
                || owner == SolanaConstants.token2022ProgramID,
            let parsed = value["data"]?.object?["parsed"]?.object,
            parsed["type"]?.string == "mint",
            let info = parsed["info"]?.object,
            let decimals = info["decimals"]?.int64,
            (0...255).contains(decimals),
            let supply = info["supply"]?.string,
            !supply.isEmpty,
            supply.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            case .bool(true) = info["isInitialized"]
        else {
            throw SolanaCustomTokenLookupError.invalidMintAccount
        }
        return Int(decimals)
    }

    private nonisolated static func metadataText(
        _ value: String?,
        maximumLength: Int
    ) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty,
            value.count <= maximumLength,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return value
    }
}

private struct JupiterTokenDescriptor: Decodable {
    struct Audit: Decodable {
        let isSus: Bool?
    }

    let id: String
    let name: String?
    let symbol: String?
    let decimals: Int?
    let isVerified: Bool?
    let liquidity: Decimal?
    let audit: Audit?

    func eligibility(
        now: Double,
        lifetime: TimeInterval
    ) -> SolanaTokenEligibility {
        let verified = isVerified == true
        let denylisted = TokenSafetyPolicy.isHardDenied(
            networkID: SolanaConstants.networkID,
            contractAddress: id
        )
        let suspicious = audit?.isSus == true || denylisted
        return SolanaTokenEligibility(
            mint: id,
            name: name,
            symbol: symbol,
            decimals: decimals,
            isVerified: verified,
            liquidityUSD: liquidity,
            isSuspicious: suspicious,
            reason: denylisted
                ? .denylisted
                : SolanaTokenEligibilityPolicy.reason(
                    isVerified: verified,
                    liquidityUSD: liquidity,
                    isSuspicious: suspicious
                ),
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: now,
            expiresAt: now + lifetime
        )
    }
}

extension WalletDatabase {
    private static let solanaNegativeEligibilityLifetime:
        TimeInterval = 15 * 60

    func resolveSolanaTokenEligibility(
        mints: Set<String>,
        fetcher: any SolanaTokenEligibilityFetching =
            SolanaTokenEligibilityClient.shared
    ) async -> [String: SolanaTokenEligibility] {
        let requestedMints = Array(mints).sorted()
        guard !requestedMints.isEmpty else {
            return [:]
        }
        let now = Date().timeIntervalSince1970
        let cachedRecords: [DBSolanaTokenEligibilityRecord]
        do {
            cachedRecords = try await pool.read { database in
                try DBSolanaTokenEligibilityRecord
                    .filter(requestedMints.contains(Column("mint")))
                    .fetchAll(database)
            }
        } catch {
            return [:]
        }
        let cachedByMint = Dictionary(
            uniqueKeysWithValues: cachedRecords.map {
                ($0.mint, $0.eligibility)
            }
        )
        var result = cachedByMint.filter { $0.value.expiresAt > now }
        let refreshMints = requestedMints.filter {
            result[$0] == nil
        }
        guard !refreshMints.isEmpty else {
            return result
        }

        do {
            let fetched = try await fetcher.fetch(mints: refreshMints)
            let refreshed = refreshMints.map { mint in
                fetched[mint] ?? SolanaTokenEligibility.unavailable(
                    mint: mint,
                    now: now,
                    lifetime: Self.solanaNegativeEligibilityLifetime
                )
            }
            try await pool.write { database in
                for eligibility in refreshed {
                    try DBSolanaTokenEligibilityRecord(
                        eligibility: eligibility
                    ).save(database)
                }
            }
            for eligibility in refreshed {
                result[eligibility.mint] = eligibility
            }
        } catch {
            for mint in refreshMints {
                if let cached = cachedByMint[mint] {
                    result[mint] = cached
                }
            }
        }
        return result
    }

    func eligibleSolanaTokenMints() async throws -> Set<String> {
        try await pool.read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: """
                    SELECT mint
                    FROM solanaTokenEligibility
                    WHERE isEligible = 1
                    """
                )
            )
        }
    }
}

extension DBSolanaTokenEligibilityRecord {
    init(eligibility: SolanaTokenEligibility) {
        self.init(
            mint: eligibility.mint,
            name: eligibility.name,
            symbol: eligibility.symbol,
            decimals: eligibility.decimals,
            isVerified: eligibility.isVerified,
            liquidityUSD: eligibility.liquidityUSD.map(
                SolanaTransactionMapper.decimalText
            ),
            isSuspicious: eligibility.isSuspicious,
            isEligible: eligibility.isEligible,
            reason: eligibility.reason.rawValue,
            provider: eligibility.provider,
            observedAt: eligibility.observedAt,
            expiresAt: eligibility.expiresAt
        )
    }

    var eligibility: SolanaTokenEligibility {
        SolanaTokenEligibility(
            mint: mint,
            name: name,
            symbol: symbol,
            decimals: decimals,
            isVerified: isVerified,
            liquidityUSD: liquidityUSD.flatMap {
                Decimal(
                    string: $0,
                    locale: Locale(identifier: "en_US_POSIX")
                )
            },
            isSuspicious: isSuspicious,
            reason: SolanaTokenEligibilityReason(rawValue: reason)
                ?? .unavailable,
            provider: provider,
            observedAt: observedAt,
            expiresAt: expiresAt
        )
    }
}

extension WalletDatabase {
    static func registerSolanaTokenEligibilityMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v22_solana_token_eligibility"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE solanaTokenEligibility (
                    mint TEXT PRIMARY KEY NOT NULL,
                    name TEXT,
                    symbol TEXT,
                    decimals INTEGER,
                    isVerified INTEGER NOT NULL,
                    liquidityUSD TEXT,
                    isSuspicious INTEGER NOT NULL,
                    isEligible INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    observedAt REAL NOT NULL,
                    expiresAt REAL NOT NULL
                );
                CREATE INDEX solanaTokenEligibility_status
                    ON solanaTokenEligibility(
                        isEligible,
                        expiresAt
                    );

                UPDATE assets
                SET isVerified = 0,
                    isSpam = 1
                WHERE networkID = 'solana'
                  AND assetType = 'fungibleToken';
                """
            )
        }
    }
}
